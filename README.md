# ccbeacon

A macOS menu bar app that tells you when your Claude Code agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What it does

ccbeacon sits in your menu bar and watches all your active Claude Code sessions. You see exactly what's happening across every session, from any app, at a glance.

| State | Menu bar |
|-------|----------|
| Idle | `✦` |
| 1 session working | `⣾ 2:14` |
| Multiple sessions | `⣾ 3 · 2:14` |
| Needs your input | `✦ 1` (amber, pulsing) |
| Just finished | `✦ done` (green, 10s) |

Click the icon to see a dropdown with per-session details: project name, model, elapsed time, and token usage.

---

## Install

### Homebrew (recommended)

```sh
brew tap hosseintoussi/ccbeacon
brew install ccbeacon
ccbeacon &
```

The hook script and `~/.claude/settings.json` entries are configured automatically during install. Just launch and go.

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

Open **System Settings → General → Login Items** and click **+** to add the ccbeacon binary.

- Homebrew install: `/opt/homebrew/bin/ccbeacon`
- Built from source: wherever your `.build/release/ccbeacon` lives

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
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh working" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }]
  }
}
```

---

## How it works

The hook script (`ccbeacon.sh`) is called by Claude Code on three events:

| Hook | State written |
|------|--------------|
| `UserPromptSubmit` | `working` |
| `Notification` | `waiting` |
| `Stop` | `done` |

Each call writes a small JSON file to `~/.claude/cc-sessions/`. ccbeacon watches that directory with `DispatchSource` for instant updates — no polling.

A `flock`-based exclusive lock in the hook script prevents a race condition where a `Notification` hook firing mid-run could overwrite a `Stop` hook running at the same moment, which would otherwise cause false "needs input" notifications after a session has already finished.

---

## Security

Everything runs locally. The hook script reads session metadata (working directory, transcript path) from Claude Code's hook stdin, writes state to `~/.claude/cc-sessions/`, and reads token counts from your local transcript files. No data leaves your machine.
