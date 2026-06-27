# ccbeacon — developer guide

## Project layout

```
Sources/
  CCBeaconCore/     Pure logic — models, formatters, session loading. No AppKit.
    Core.swift      Session/DailyStats structs, loadSessions(), fmtElapsed(), etc.
    Version.swift   appVersion constant + isDevBuild detection (path-based)
  ccbeacon/         AppKit menu bar app
    AppDelegate.swift  NSStatusItem, menu building, notifications, file watching
    Views.swift        SpinnerView, PulseDotView, DoneCircleView (CALayer animations)
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

The menu bar button shows `✦` at idle, a Braille spinner + elapsed time while working,
and an amber pulsing glyph when a session needs input.

## Test

```sh
swift run CCBeaconTests
```

No testing framework required — runs with Command Line Tools alone (no Xcode needed).
Tests cover: `fmtElapsed`, `fmtClock`, `fmtK`, `cleanModel`, `Session.priority`, `Session.dirName`.

## Hook script setup (required to see sessions)

**Homebrew install:** handled automatically by `post_install` — hook script copied to
`~/.claude/hooks/ccbeacon.sh` and entries merged into `~/.claude/settings.json`.

**Dev build:** do it manually:

```sh
mkdir -p ~/.claude/hooks
cp ccbeacon.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/ccbeacon.sh
```

Add to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh working" }] }],
    "Notification":     [{ "matcher": "permission_prompt",  "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] },
                         { "matcher": "elicitation_dialog", "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh waiting" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/ccbeacon.sh done"    }] }]
  }
}
```

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
- Create the GitHub release
- Update the SHA256 in the Homebrew tap formula

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
  mtime before firing a notification.

- **CALayer frame fix:** `SpinnerView` and `PulseDotView` set `sublayer.frame` explicitly
  before adding animations. Without this, `anchorPoint (0.5, 0.5)` maps to position `(0,0)`
  and rotations pivot around the corner instead of the center.

- **Menu bar text color:** `NSColor.labelColor` appears black on light backgrounds.
  Use `NSColor.white.withAlphaComponent(0.75)` for menu bar button text.

- **Dev detection:** `isDevBuild` checks `CommandLine.arguments[0]` — any path not under
  `/opt/homebrew` or `/usr/local` is treated as a dev build and shows an orange "dev" badge
  in the dropdown header.
