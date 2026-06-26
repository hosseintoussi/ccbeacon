# Changelog

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
