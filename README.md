# ai-cli-auto-retry

> Automatically retry coding agent sessions when you hit rate limits. Works with **any provider** — Anthropic, OpenAI, Google, GitHub Copilot, and more. Optionally switches to a fallback model instead of waiting.

When your coding agent shows *"5-hour limit reached — resets 3pm"*, this tool waits for the reset and sends "continue" automatically. Or, if you configure it, switches to a fallback model instantly so work never stops.

**Pure Bash. Single file. No dependencies beyond tmux + coreutils.**

---

## The Problem

You're in the middle of a complex task with pi, Claude Code, or another coding agent. After a while:

```
You've hit your limit · resets 3pm (Europe/Dublin)
```

The agent stops. You have to wait hours, come back, and type "continue". If you're running long tasks overnight or while AFK, this kills your productivity.

## The Solution

```bash
curl -fsSL https://raw.githubusercontent.com/your-user/auto-retry/main/auto-retry -o ~/.local/bin/auto-retry
chmod +x ~/.local/bin/ai-cli-auto-retry
ai-cli-auto-retry install
```

That's it. Use `pi` or `claude` as you always do. When a rate limit hits, the tool:

1. Detects the rate limit message in the terminal (any provider)
2. Parses the reset time (timezone-aware)
3. Waits until the limit resets + 60s margin
4. Verifies the agent is still the foreground process
5. Sends "continue" automatically (or switches to a fallback model)

## How it Works

```
You type "pi" or "claude"
       │
       ▼
  Shell function (injected in .bashrc/.zshrc)
       │
       ├─ Already in tmux? ──▶ Start background monitor
       │                        Launch agent with full TUI
       │
       └─ Not in tmux? ──▶ Create tmux session transparently
                             Launch agent + monitor inside
                             Attach (looks the same to you)

  MONITOR (background, ~0% CPU):
       │
       ├─ Polls tmux pane every 5 seconds
       ├─ Detects rate limit text (any provider)
       ├─ Parses reset time from message
       ├─ Waits until reset + safety margin
       ├─ Verifies agent is still the foreground process
       ├─ (Optional) Switches to fallback model via /model
       └─ Sends "continue" via tmux send-keys
```

## Supported Providers

| Provider | Rate Limit Patterns Detected |
|----------|-----|
| **Anthropic / Claude** | "5-hour limit reached", "hit your limit", "out of extra usage", "usage limit" |
| **OpenAI** | "Rate limit reached", "Too many requests", "try again in" |
| **Google / Gemini** | "Resource exhausted", "Quota exceeded" |
| **GitHub Copilot** | "Rate limit exceeded" |
| **Generic** | Any "limit reached" + "resets" pattern |

Custom patterns can be added via config.

## Auto Model Switching (Opt-in)

The killer feature. Instead of waiting hours, switch to a fallback model instantly.

```json
{
  "autoModelSwitch": {
    "enabled": true,
    "fallbackChain": [
      "claude-sonnet-4-20250514",
      "gpt-4o",
      "gemini-2.5-pro"
    ],
    "switchCommand": "/model",
    "restoreOriginal": true,
    "switchDelaySeconds": 3
  }
}
```

When rate-limited on your primary model:
1. Sends `/model claude-sonnet-4-20250514` → waits 3s → sends "continue"
2. If that model is also rate-limited → tries `gpt-4o`
3. If all fallbacks exhausted → waits for original reset time
4. When rate limit clears → restores your original model

**Disabled by default.** Enable explicitly in `~/.ai-cli-auto-retry.json`.

## Configuration

Optional. Create `~/.ai-cli-auto-retry.json`:

```json
{
  "targets": ["pi", "claude"],
  "maxRetries": 5,
  "pollIntervalSeconds": 5,
  "marginSeconds": 60,
  "fallbackWaitHours": 5,
  "retryMessage": "Continue where you left off. The previous attempt was rate limited.",
  "autoModelSwitch": {
    "enabled": false,
    "fallbackChain": [],
    "switchCommand": "/model",
    "restoreOriginal": true,
    "switchDelaySeconds": 3
  },
  "customPatterns": [],
  "foregroundCommands": ["node", "claude", "pi", "npx", "tsx", "bun", "deno"],
  "logRetentionDays": 7
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `targets` | `["pi", "claude"]` | Commands to wrap with ai-cli-auto-retry |
| `maxRetries` | `5` | Max retry attempts per rate-limit event |
| `pollIntervalSeconds` | `5` | How often to check the terminal |
| `marginSeconds` | `60` | Extra wait after reset time |
| `fallbackWaitHours` | `5` | Wait time if reset time can't be parsed |
| `retryMessage` | `"Continue where..."` | Message sent on retry |
| `autoModelSwitch.enabled` | `false` | Enable model fallback |
| `autoModelSwitch.fallbackChain` | `[]` | Ordered fallback models |
| `autoModelSwitch.switchCommand` | `"/model"` | Command to switch models |
| `autoModelSwitch.restoreOriginal` | `true` | Switch back after rate limit clears |
| `autoModelSwitch.switchDelaySeconds` | `3` | Wait between switch and retry |
| `customPatterns` | `[]` | Additional regex patterns (grep -E) |
| `foregroundCommands` | `["node", ...]` | Process names considered safe for send-keys |
| `logRetentionDays` | `7` | Days to keep log files |

## CLI Commands

```bash
ai-cli-auto-retry install       # Install shell wrappers + check tmux
ai-cli-auto-retry uninstall     # Remove shell wrappers
ai-cli-auto-retry status        # Show monitor activity + last log entries
ai-cli-auto-retry logs          # Tail today's log file
ai-cli-auto-retry version       # Print version
ai-cli-auto-retry help          # Show help
```

## Requirements

- **Bash** >= 3.2 (ships with macOS)
- **tmux** >= 2.1 (auto-detected, instructions to install if missing)
- **coreutils** (grep, sed, date, ps, sleep, wc — standard on all Unix)

Optional: `jq` for faster JSON parsing (falls back to grep/sed if not available)

## Platform Support

| OS | Status |
|----|--------|
| macOS | ✓ (bash 3.2 compatible, BSD date supported) |
| Ubuntu / Debian | ✓ |
| CentOS / RHEL / Fedora | ✓ |
| Arch Linux | ✓ |
| Alpine | ✓ |
| WSL | ✓ |

| Shell | Status |
|-------|--------|
| bash | ✓ Auto-install to `~/.bashrc` |
| zsh | ✓ Auto-install to `~/.zshrc` |
| fish | Manual (instructions printed) |

## `--print` Mode

For scripted/piped usage (`pi -p "..." | jq`):

1. Buffers all output
2. If rate-limited: discards output, waits, re-executes
3. Returns a single clean response

```bash
pi -p "Generate a JSON schema" | jq .
```

## Logging

Logs written to `~/.ai-cli-auto-retry/logs/YYYY-MM-DD.log`:

```
[2026-04-01 15:00:05] [INFO] Monitor started for pane %3 (pi PID: 12345)
[2026-04-01 15:32:10] [INFO] Rate limit detected: "5-hour limit reached - resets 3pm". Waiting 3547s...
[2026-04-01 15:32:12] [INFO] Switching to fallback model: gpt-4o (attempt 1)
[2026-04-01 16:01:10] [INFO] Rate limit cleared. Resuming monitoring.
[2026-04-01 16:01:11] [INFO] Restoring original model: claude-sonnet-4-20250514
```

## Uninstall

```bash
ai-cli-auto-retry uninstall
rm ~/.local/bin/ai-cli-auto-retry  # or wherever you put it
```

## Compared to claude-auto-retry

| Feature | claude-auto-retry | ai-cli-auto-retry |
|---------|-------------------|------------|
| Language | Node.js (~40MB RSS) | Bash (< 1MB RSS) |
| Dependencies | Node.js >= 18 | None (bash + tmux) |
| Distribution | `npm i -g` | Single file, `curl` install |
| Providers | Claude only | Any provider |
| Model switching | No | Yes (opt-in) |
| Target tools | Claude Code only | pi, claude, any |
| Custom patterns | Yes | Yes |
| macOS compat | Needs Node.js | Stock bash 3.2 |

## Development

```bash
git clone https://github.com/your-user/ai-cli-auto-retry
cd ai-cli-auto-retry
./test/test.sh    # Run 51 tests
```

## License

MIT
