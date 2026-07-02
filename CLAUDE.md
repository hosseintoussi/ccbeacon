# ccbeacon — developer guide

## Project layout

```
Sources/
  CCBeaconCore/     Pure logic — models, formatters, session loading. No AppKit.
    Core.swift      Session/DailyStats structs, loadSessions(), fmtElapsed(), etc.
    Version.swift   appVersion constant + isDevBuild detection (path-based)
  ccbeacon/         AppKit menu bar app
    AppDelegate.swift  NSStatusItem, menu building, notifications, file watching
    Views.swift        SessionCardView (card bg + hover/click), SpinnerView, PulseDotView, IdleDotView
    Snapshot.swift     --snapshot flag: renders the dropdown to PNGs for design review
    main.swift         Entry point
Tests/
  CCBeaconCoreTests/  Framework-free test runner (no XCTest needed)
ccbeacon.sh           Claude Code hook script — writes session state files
```

AppKit code lives only in `Sources/ccbeacon/`. Everything testable goes in `CCBeaconCore`.

## Build and run

```sh
swift build -c release
.build/release/ccbeacon &       # runs as dev build — shows "dev" badge in dropdown
```

The menu bar button shows `>_` at idle, a Braille spinner + elapsed time while working,
and an amber pulsing glyph when a session needs input.

To review dropdown layout/color changes without clicking through the menu bar:

```sh
.build/release/ccbeacon --snapshot /tmp   # writes menu-dark.png + menu-light.png
```

## Test

```sh
swift run CCBeaconTests
```

No testing framework required — runs with Command Line Tools alone (no Xcode needed).
Tests cover: formatters (`fmtElapsed`, `fmtBarTime`, `fmtK`, `cleanModel`), `Session.priority`,
`Session.dirName`, `processStartTime`, `readTokens` (incremental parsing, partial lines,
truncation), and `loadSessions` (state resolution, staleness, PID recycling, sort order).

## Hook script setup (required to see sessions)

Automatic: `syncClaudeIntegration()` (`Sources/ccbeacon/Setup.swift`) runs at every
launch. It copies the bundled `ccbeacon.sh` to `~/.claude/hooks/` when contents differ
(dev builds resolve it from the repo root, Homebrew builds from the keg's `libexec`)
and merges any missing hook entries into `~/.claude/settings.json` via
`mergedHookSettings()` in CCBeaconCore. Events that already contain a ccbeacon entry
are never modified.

This lives in the app — NOT in the Homebrew formula — because `post_install` runs in
Homebrew's sandbox with a fake `$HOME` and cannot write the user's real `~/.claude`.
Note: launching a dev build overwrites the user-installed hook with the repo version.

## Releasing a new version

1. Add a `## [X.Y.Z] - YYYY-MM-DD` section at the top of `CHANGELOG.md`
2. Bump `appVersion` in `Sources/CCBeaconCore/Version.swift`
3. Commit and tag:
   ```sh
   git commit -am "Bump to vX.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The release workflow (`.github/workflows/release.yml`) is triggered automatically once CI
passes on the pushed commit. It will:
- Detect the version tag on that commit
- Extract the matching `## [X.Y.Z]` section from `CHANGELOG.md` as the release body
- Build a universal (arm64 + x86_64) binary and attach `ccbeacon-vX.Y.Z-macos.tar.gz`
  (binary + hook script) to the GitHub release
- Point the Homebrew tap formula at the binary asset and update its SHA256

**If CI fails, the release will not run.**


## Homebrew tap

The tap lives at `github.com/hosseintoussi/homebrew-ccbeacon`.
Formula: `Formula/ccbeacon.rb` — install command: `brew tap hosseintoussi/ccbeacon && brew install ccbeacon`.

To manually update the formula after a release (if the workflow didn't run):
```sh
cd /path/to/homebrew-ccbeacon
# update url and sha256 in Formula/ccbeacon.rb
git commit -am "ccbeacon vX.Y.Z"
git push
```

## Key implementation details

- **False notification prevention:** `fcntl.flock(LOCK_EX)` in `ccbeacon.sh` serializes
  concurrent hook processes so a `Notification` hook can't overwrite a `Stop` that ran
  simultaneously. The app also debounces "waiting" state for 8 seconds and checks transcript
  mtime before playing a sound.

- **Atomic state files:** the hook writes to `<session>.json.tmp` and `os.replace()`s it —
  the app reads without the lock, so the rename guarantees it never sees a half-written
  file. The rename also fires the directory watcher, giving instant menu bar updates.

- **SessionEnd deletes the state file** (detected via `hook_event_name` on stdin, so all
  hook events can pass the same-looking args). A quit session vanishes instead of passing
  through "done", which would chime "finished" for a session the user killed.

- **PID recycling:** a session is alive only if `kill(pid, 0)` succeeds *and* the process
  start time (via `sysctl KERN_PROC_PID`) predates the session's last hook event. Claude
  always starts before its first hook fires, so a later start time means the PID was reused.

- **Incremental transcript parsing:** `readTokens` caches a byte offset per transcript and
  parses only appended complete lines. Never re-read whole transcripts on the update tick —
  they can be tens of MB and `update()` runs every second on the main thread.

- **CALayer frame fix:** `SpinnerView` and `PulseDotView` set `sublayer.frame` explicitly
  before adding animations. Without this, `anchorPoint (0.5, 0.5)` maps to position `(0,0)`
  and rotations pivot around the corner instead of the center.

- **Menu bar text color:** use dynamic system colors (`NSColor.labelColor`) for the status
  button text so it adapts to light and dark menu bars. Never hardcode white or snapshot a
  dynamic color's `cgColor` for text — it becomes invisible on a light menu bar.

- **Update timer runs in `.common` run-loop mode** — in `.default` mode timers stop firing
  while the status item menu is tracking, freezing the spinner and elapsed times.

- **Dev detection:** `isDevBuild` checks `CommandLine.arguments[0]` — any path not under
  `/opt/homebrew` or `/usr/local` is treated as a dev build and shows an orange "dev" badge
  in the dropdown header.
