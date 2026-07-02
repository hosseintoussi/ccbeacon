# >_ ccbeacon

A macOS menu bar app that tells you when your Claude Code agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What it does

ccbeacon sits in your menu bar and watches all your active Claude Code sessions. You see exactly what's happening across every session, from any app, at a glance.

| State | Menu bar |
|-------|----------|
| No active sessions | `>_` |
| 1 session working | `⣾ 2:14` |
| Multiple sessions working | `⣾ 3 sessions` |
| Needs your input | `>_ 1` (amber, pulsing) |
| Just finished | `>_ Done` (green, 10s) |

Click the icon to see a dropdown with per-session details: project name, model, path, and token usage. Click a session row to jump directly to that terminal pane (iTerm2 and Terminal.app supported).

---

## Install

### Homebrew (recommended)

```sh
brew tap hosseintoussi/ccbeacon
brew install ccbeacon
ccbeacon &
```

The hook script, `~/.claude/settings.json` entries, and login launch are all configured automatically. ccbeacon starts immediately and on every login.

### Update

```sh
brew update && brew upgrade ccbeacon
pkill ccbeacon; ccbeacon &
```

### Build from source

Requires macOS 13+ and Swift (via Xcode or Command Line Tools).

```sh
git clone https://github.com/hosseintoussi/ccbeacon.git
cd ccbeacon
swift build -c release
.build/release/ccbeacon &
```

Then follow the [manual hook setup](#manual-hook-setup) steps below.

---

## Launch at login

**Homebrew install:** handled automatically — a LaunchAgent is installed during `brew install` so ccbeacon starts on every login.

**Built from source:** add a LaunchAgent manually:

```sh
cat > ~/Library/LaunchAgents/com.hosseintoussi.ccbeacon.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hosseintoussi.ccbeacon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/.build/release/ccbeacon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hosseintoussi.ccbeacon.plist
```

---

## Manual hook setup

Only needed if you built from source. Homebrew handles this automatically.

### 1. Install the hook script

```sh
mkdir -p ~/.claude/hooks
cp ccbeacon.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/ccbeacon.sh
```

### 2. Configure Claude Code hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":    [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh idle"    }] }],
    "UserPromptSubmit":[{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh working" }] }],
    "Notification":    [{ "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] },
                        { "matcher": "elicitation_dialog", "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] }],
    "Stop":            [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }],
    "StopFailure":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }],
    "SessionEnd":      [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }]
  }
}
```

---

## How it works

The hook script (`ccbeacon.sh`) is called by Claude Code on these events:

| Hook | Matcher | State written |
|------|---------|--------------|
| `SessionStart` | — | `idle` |
| `UserPromptSubmit` | — | `working` |
| `Notification` | `permission_prompt` | `waiting` |
| `Notification` | `elicitation_dialog` | `waiting` |
| `Stop` | — | `done` |
| `StopFailure` | — | `done` |
| `SessionEnd` | — | session file removed |

Each call atomically writes a small JSON file to `~/.claude/cc-sessions/` including the session's PID, TTY device, and terminal app. ccbeacon watches that directory with `DispatchSource` so state changes appear instantly, plus a 1-second refresh for elapsed times and staleness checks.

Sessions are kept alive as long as their Claude process is running (verified via `kill(pid, 0)` plus a process start-time check that guards against PID reuse). When the session ends — whether from a normal close or the process exiting — it disappears from the menu immediately.

Two `Notification` matchers trigger the amber "needs input" state: `permission_prompt` (tool approval dialogs) and `elicitation_dialog` (option/question UI rendered by Claude). Other notification types are ignored.

A `flock`-based exclusive lock in the hook script prevents a race condition where a `Notification` hook firing mid-run could overwrite a `Stop` hook running at the same moment.

---

## Security

Everything runs locally. The hook script reads session metadata from Claude Code's hook stdin and writes state to `~/.claude/cc-sessions/`. The app reads per-session token counts from your local transcript files. No data leaves your machine.
