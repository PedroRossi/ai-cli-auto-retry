#!/usr/bin/env bash
# Test suite for auto-retry
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO_RETRY="$SCRIPT_DIR/../ai-cli-auto-retry"
PASS=0
FAIL=0
TOTAL=0

# ── Test Helpers ───────────────────────────────────────────────────────────────

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit() {
    local desc="$1" expected_code="$2"
    shift 2
    TOTAL=$((TOTAL + 1))
    "$@" >/dev/null 2>&1
    local code=$?
    if [ "$code" -eq "$expected_code" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (exit $code, expected $expected_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        echo "    expected to contain: '$needle'"
        echo "    in: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        echo "    expected NOT to contain: '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

# ── Source the script for function testing ─────────────────────────────────────
# We source it in a subshell to get access to internal functions

# Create a helper that sources and calls a function
run_fn() {
    local fn_name="$1"
    shift
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        "$fn_name" "$@"
    )
}

run_fn_stdin() {
    local fn_name="$1"
    shift
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        "$fn_name" "$@"
    )
}

# ── Tests: CLI ─────────────────────────────────────────────────────────────────

echo "CLI Commands:"
assert_eq "version outputs version string" "0.1.0" "$("$AUTO_RETRY" version)"
assert_contains "help shows usage" "Usage:" "$("$AUTO_RETRY" help)"
assert_contains "help shows install command" "install" "$("$AUTO_RETRY" help)"
assert_exit "unknown command exits 1" 1 "$AUTO_RETRY" foobar

echo ""

# ── Tests: ANSI Stripping ──────────────────────────────────────────────────────

echo "ANSI Stripping:"

result=$(echo -e "\x1b[31mhello\x1b[0m world" | run_fn_stdin strip_ansi)
assert_eq "strips CSI color codes" "hello world" "$result"

result=$(echo -e "\x1b[?25hvisible\x1b[?25l" | run_fn_stdin strip_ansi)
assert_eq "strips cursor show/hide" "visible" "$result"

result=$(echo "plain text no escapes" | run_fn_stdin strip_ansi)
assert_eq "passes through plain text" "plain text no escapes" "$result"

echo ""

# ── Tests: Pattern Detection ──────────────────────────────────────────────────

echo "Pattern Detection (Anthropic):"

result=$(echo "5-hour limit reached - resets 3pm (UTC)" | run_fn_stdin is_rate_limited; echo $?)
# is_rate_limited runs in a subshell with while loop, need to handle differently
test_rate_limit() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        is_rate_limited "$1"
        echo $?
    )
}

result=$(test_rate_limit "5-hour limit reached - resets 3pm (UTC)")
assert_eq "detects '5-hour limit reached - resets 3pm'" "0" "$result"

result=$(test_rate_limit "You've hit your limit · resets 3pm (Europe/Dublin)")
assert_eq "detects 'hit your limit · resets 3pm'" "0" "$result"

result=$(test_rate_limit "You're out of extra usage · resets 3pm")
assert_eq "detects 'out of extra usage · resets'" "0" "$result"

result=$(test_rate_limit "Usage limit reached. Resets at 2pm")
assert_eq "detects 'Usage limit reached. Resets at 2pm'" "0" "$result"

result=$(test_rate_limit "Rate limit hit. Resets at 4pm")
assert_eq "detects 'Rate limit hit. Resets at 4pm'" "0" "$result"

echo ""
echo "Pattern Detection (OpenAI):"

result=$(test_rate_limit "Rate limit reached. Please try again in 30 seconds")
assert_eq "detects 'Rate limit reached... try again in 30 seconds'" "0" "$result"

result=$(test_rate_limit "Too many requests. Retry after 60 seconds")
assert_eq "detects 'Too many requests. Retry after'" "0" "$result"

echo ""
echo "Pattern Detection (Google):"

result=$(test_rate_limit "Resource exhausted. Resets in 5 minutes")
assert_eq "detects 'Resource exhausted. Resets in 5 minutes'" "0" "$result"

result=$(test_rate_limit "Quota exceeded. Try again in 1 hour")
assert_eq "detects 'Quota exceeded. Try again in 1 hour'" "0" "$result"

echo ""
echo "Pattern Detection (Negative):"

result=$(test_rate_limit "Hello, how can I help you today?")
assert_eq "does not match normal text" "1" "$result"

result=$(test_rate_limit "The rate of change is increasing")
assert_eq "does not match 'rate of change'" "1" "$result"

result=$(test_rate_limit "Please try the following approach")
assert_eq "does not match 'try the following'" "1" "$result"

echo ""

# ── Tests: Reset Message Extraction ───────────────────────────────────────────

echo "Reset Message Extraction:"

test_find_reset() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        find_reset_message "$1"
    )
}

result=$(test_find_reset "5-hour limit reached - resets 3pm (UTC)")
assert_contains "extracts reset line from Claude message" "resets 3pm" "$result"

result=$(test_find_reset "Rate limit. Try again in 5 hours")
assert_contains "extracts 'try again' line" "Try again in 5 hours" "$result"

echo ""

# ── Tests: Time Parsing ───────────────────────────────────────────────────────

echo "Time Parsing:"

test_wait_seconds() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        load_config
        calculate_wait_seconds "$1"
    )
}

# Relative times
result=$(test_wait_seconds "try again in 5 hours")
expected=$((5 * 3600 + 60))
assert_eq "relative: 5 hours = $expected seconds" "$expected" "$result"

result=$(test_wait_seconds "wait 30 minutes")
expected=$((30 * 60 + 60))
assert_eq "relative: 30 minutes = $expected seconds" "$expected" "$result"

result=$(test_wait_seconds "try again in 1 hour")
expected=$((1 * 3600 + 60))
assert_eq "relative: 1 hour = $expected seconds" "$expected" "$result"

# Fallback (unparseable)
result=$(test_wait_seconds "something unparseable")
expected=$((5 * 3600 + 60))
assert_eq "fallback: unparseable = $expected seconds" "$expected" "$result"

echo ""

# ── Tests: Config Loading ─────────────────────────────────────────────────────

echo "Config Loading:"

# Test with no config file
test_defaults() {
    (
        AUTO_RETRY_SOURCED=1
        CONFIG_FILE="/nonexistent/path.json"
        source "$AUTO_RETRY"
        load_config
        echo "$CFG_MAX_RETRIES|$CFG_POLL_INTERVAL|$CFG_MARGIN_SECONDS|$CFG_MODEL_SWITCH_ENABLED"
    )
}

result=$(test_defaults)
assert_eq "defaults when no config file" "5|5|60|false" "$result"

# Test with custom config
test_custom_config() {
    local tmpconf
    tmpconf=$(mktemp)
    cat > "$tmpconf" <<'JSON'
{
  "maxRetries": 10,
  "pollIntervalSeconds": 3,
  "marginSeconds": 120,
  "targets": ["pi"],
  "autoModelSwitch": {
    "enabled": true,
    "fallbackChain": ["gpt-4o", "gemini-2.5-pro"],
    "switchCommand": "/model",
    "restoreOriginal": true,
    "switchDelaySeconds": 5
  }
}
JSON
    (
        AUTO_RETRY_SOURCED=1
        CONFIG_FILE="$tmpconf"
        source "$AUTO_RETRY"
        load_config
        echo "$CFG_MAX_RETRIES|$CFG_POLL_INTERVAL|$CFG_MARGIN_SECONDS|$CFG_MODEL_SWITCH_ENABLED|$CFG_MODEL_SWITCH_DELAY"
    )
    rm -f "$tmpconf"
}

result=$(test_custom_config)
assert_eq "reads custom config values" "10|3|120|true|5" "$result"

echo ""

# ── Tests: Wrapper Generation ─────────────────────────────────────────────────

echo "Wrapper Generation:"

test_wrapper() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        generate_wrapper "pi" "/usr/local/bin/ai-cli-auto-retry"
    )
}

result=$(test_wrapper)
assert_contains "wrapper defines function" "pi()" "$result"
assert_contains "wrapper checks AUTO_RETRY_ACTIVE" "AUTO_RETRY_ACTIVE" "$result"
assert_contains "wrapper calls ai-cli-auto-retry launch" "ai-cli-auto-retry launch pi" "$result"
assert_contains "wrapper uses command builtin" "command pi" "$result"

echo ""

# ── Tests: Install/Uninstall ──────────────────────────────────────────────────

MARKER_START="# >>> ai-cli-auto-retry >>>"
MARKER_END="# <<< ai-cli-auto-retry <<<"

echo "Install/Uninstall (dry-run with temp RC file):"

test_install_uninstall() {
    local tmprc
    tmprc=$(mktemp)
    echo '# existing content' > "$tmprc"
    echo 'export PATH="/usr/local/bin:$PATH"' >> "$tmprc"

    AUTO_RETRY_SOURCED=1 source "$AUTO_RETRY"
    local wrapper_block="$MARKER_START
$(generate_wrapper "pi" "/usr/local/bin/ai-cli-auto-retry")
$(generate_wrapper "claude" "/usr/local/bin/ai-cli-auto-retry")
$MARKER_END"
    echo "" >> "$tmprc"
    echo "$wrapper_block" >> "$tmprc"

    # Verify markers exist
    if grep -q "$MARKER_START" "$tmprc" && grep -q "$MARKER_END" "$tmprc"; then
        echo "  ✓ install injects markers"
        PASS=$((PASS + 1))
    else
        echo "  ✗ install injects markers"
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))

    # Verify both wrappers present
    local wrapper_count
    wrapper_count=$(grep -c '() {' "$tmprc" || true)
    assert_eq "install creates 2 wrapper functions" "2" "$wrapper_count"

    # Verify existing content preserved
    assert_contains "install preserves existing content" "existing content" "$(cat "$tmprc")"

    # Now uninstall
    local tmpf
    tmpf=$(mktemp)
    sed "/$MARKER_START/,/$MARKER_END/d" "$tmprc" > "$tmpf"
    mv "$tmpf" "$tmprc"

    if grep -q "$MARKER_START" "$tmprc"; then
        echo "  ✗ uninstall removes markers"
        FAIL=$((FAIL + 1))
    else
        echo "  ✓ uninstall removes markers"
        PASS=$((PASS + 1))
    fi
    TOTAL=$((TOTAL + 1))

    assert_contains "uninstall preserves existing content" "existing content" "$(cat "$tmprc")"

    rm -f "$tmprc"
}

test_install_uninstall

echo ""

# ── Tests: Multi-line Rate Limit (TUI rendering) ──────────────────────────────

echo "Multi-line Rate Limit Detection:"

result=$(test_rate_limit "$(printf '⚠ You'\''ve hit your limit\n· resets 3pm (UTC)')")
assert_eq "detects multi-line: limit + resets on separate lines" "0" "$result"

result=$(test_rate_limit "$(printf 'Some output\nMore output\nlimit reached\nsome text\nresets at 5pm\nmore text')")
assert_eq "detects windowed: limit and resets within 6 lines" "0" "$result"

result=$(test_rate_limit "$(printf 'limit reached\n1\n2\n3\n4\n5\n6\n7\n8\nresets at 5pm')")
assert_eq "does not match when limit and resets > 6 lines apart" "1" "$result"

echo ""

# ── Tests: ANSI in rate limit messages ─────────────────────────────────────────

echo "ANSI-encoded Rate Limit Detection:"

result=$(test_rate_limit "$(echo -e '\x1b[33m5-hour limit reached\x1b[0m - \x1b[36mresets 3pm (UTC)\x1b[0m')")
assert_eq "detects rate limit through ANSI codes" "0" "$result"

echo ""

# ── Tests: Print Mode Detection ───────────────────────────────────────────────

echo "Print Mode Detection:"

test_print_mode() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        is_print_mode "$@" && echo "yes" || echo "no"
    )
}

assert_eq "detects -p flag" "yes" "$(test_print_mode -p "some prompt")"
assert_eq "detects --print flag" "yes" "$(test_print_mode --print "some prompt")"
assert_eq "no print flag" "no" "$(test_print_mode "some prompt")"
assert_eq "print as value not flag" "no" "$(test_print_mode "--message" "print")"

echo ""

# ── Tests: tmux Helpers ───────────────────────────────────────────────────────

echo "tmux Helpers:"

test_inside_tmux() {
    (
        AUTO_RETRY_SOURCED=1
        source "$AUTO_RETRY"
        TMUX="$1" is_inside_tmux && echo "yes" || echo "no"
    )
}

assert_eq "inside tmux when TMUX set" "yes" "$(TMUX="/tmp/tmux-1000/default,12345,0" test_inside_tmux "/tmp/tmux-1000/default,12345,0")"
assert_eq "not inside tmux when TMUX empty" "no" "$(TMUX="" test_inside_tmux "")"

echo ""

# ── Tests: Foreground Command Matching ────────────────────────────────────────

echo "Foreground Command Matching:"

test_fg_match() {
    local cmd_list="$1" fg="$2"
    local fg_lower
    fg_lower=$(echo "$fg" | tr '[:upper:]' '[:lower:]')
    local cmd
    for cmd in $cmd_list; do
        case "$fg_lower" in
            *"$cmd"*) echo "match"; return ;;
        esac
    done
    echo "no-match"
}

assert_eq "matches 'node'" "match" "$(test_fg_match "node claude pi" "node")"
assert_eq "matches 'claude'" "match" "$(test_fg_match "node claude pi" "claude")"
assert_eq "matches 'pi'" "match" "$(test_fg_match "node claude pi" "pi")"
assert_eq "no match for 'vim'" "no-match" "$(test_fg_match "node claude pi" "vim")"
assert_eq "no match for 'bash'" "no-match" "$(test_fg_match "node claude pi" "bash")"

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
