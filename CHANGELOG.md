# Changelog

## [2.0.3] - 2026-06-27

### Changed
- Daily stats row now reads from Claude Code's own `~/.claude/stats-cache.json` and shows sessions, messages, and tool calls for today — no more homegrown token accounting
- Removed token-counting transcript parsing from the Stop hook; hook script is significantly simpler

## [2.0.2] - 2026-06-26

### Fixed
- Removed false "needs input" notifications triggered by any response ending with `?` — `waiting` state now only fires from the `Notification` hook with `matcher: permission_prompt`, which is the correct signal for Claude Code's option/question UI
- Removed unused `asking` state and its purple UI (tint, stripe, `?` icon, "has question" notification)

## [2.0.1] - 2026-06-26

### Fixed
- Session rows now show model, path, and token stats on separate lines — no more truncation
- Daily stats row stacks token counts below the session count so the full string is visible

## [2.0.0] - 2026-06-26

### Added
- **Terminal deep-link:** click any session row to jump directly to that terminal pane — works with iTerm2 and Terminal.app via AppleScript
- **Pill-style "open" button** replaces elapsed time in session rows when a TTY is detected; hand cursor on hover signals it's clickable
- **SessionStart hook** — fresh sessions appear immediately without needing to type first
- **PID-based liveness detection** — sessions disappear instantly when their Claude process exits, no more stale entries lingering for minutes
- **`idle` state** — sessions in `done` state with a live process are resolved to `idle` and stay visible; removed the moment the process exits
- **Multi-session taskbar** — two or more active sessions shows "N sessions" instead of elapsed time
- Hook detects terminal app (iTerm2 / Terminal.app) and per-pane TTY device by walking the process tree

### Fixed
- Sessions not disappearing after closing a terminal
- Sessions stuck in "waiting" after tool approval (resolved via transcript mtime check)
- False "input needed" notifications from recap messages (now uses `matcher: "permission_prompt"` on the Notification hook)
- Green elapsed time color removed from session rows

## [1.1.2] - 2026-06-26

### Fixed
- Dev badge incorrectly shown on Homebrew installs — now uses `Bundle.main.executablePath` instead of `argv[0]` for reliable install path detection
- LaunchAgent installed automatically at login via `brew install`

## [1.1.1] - 2026-06-26

### Fixed
- Release workflow now correctly uses CHANGELOG.md for release notes

## [1.1.0] - 2026-06-26

### Added
- Version number and `dev` badge visible in menu dropdown header
- GitHub Actions CI (build + test on every push and PR)
- GitHub Actions release workflow — tag a version to publish automatically
- Homebrew `post_install` now auto-installs the hook script and configures `~/.claude/settings.json`

### Fixed
- Version text color in dropdown was invisible (switched to `secondaryLabelColor`)

## [1.0.0] - 2026-06-26

Initial release.

- macOS menu bar app monitoring all active Claude Code sessions
- Spinning indicator with elapsed time while working
- Pulsing amber dot + Sosumi sound when a session needs input
- Green flash + Glass sound when a session finishes
- Dropdown with per-session details: project, model, elapsed time, token usage
- Daily token usage summary
- `flock`-based hook script prevents false "needs input" notifications
- 8-second debounce with transcript recency check as belt-and-suspenders
- Homebrew tap: `brew tap hosseintoussi/ccbeacon && brew install ccbeacon`
