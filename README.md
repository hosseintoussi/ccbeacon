# ccbeacon

A macOS menu bar app that tells you when your Claude Code agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What ccbeacon does

It sits in your menu bar and watches all your active Claude Code sessions. You see exactly what's happening across every session, from any app, at a glance.

- When Claude is working: a spinning indicator and elapsed time
- When Claude needs your input: an amber pulsing dot with a sound notification
- When Claude finishes: a green flash and a chime

Open the dropdown for per-session detail: project name, model, elapsed time, token usage.

| State | Menu bar |
|-------|----------|
| Idle | `✦` |
| 1 session working | `⣾ 2:14` |
| Multiple sessions | `⣾ 3 · 2:14` |
| Needs your input | `✦ 1` (amber, pulsing) |
| Just finished | `✦ done` (green, 10s) |

## How it works

Three Claude Code hooks write session state to `~/.claude/cc-sessions/` as your sessions progress. ccbeacon watches that directory with `DispatchSource` for instant updates — no polling.

A `flock`-based lock in the hook script prevents a race condition where a `Notification` hook fired mid-run could overwrite a `Stop` hook that ran at the same moment, causing false "needs input" notifications after a session has already completed.

## Requirements

- macOS 13+
- Swift 5.9+ (`swift --version`)
- [Claude Code](https://claude.ai/code)

## Build

```sh
git clone https://github.com/hosseintoussi/ccbeacon.git
cd ccbeacon
swift build -c release
```

The binary is at `.build/release/ccbeacon`.

## Setup

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
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh working" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }]
  }
}
```

### 3. Launch

```sh
.build/release/ccbeacon &
```

To start at login, add it to **System Settings → General → Login Items**.

## Tests

```sh
swift run CCBeaconTests
```
