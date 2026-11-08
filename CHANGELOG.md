# Changelog

All notable changes to Mixarchy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-11-08

### Added
- **Now Playing Expanded View**:
  - **Full-Size Cover Art**: High-resolution, adaptive artwork rendering with smooth transitions.
  - **100% Local Synchronized Lyrics**: Zero cloud dependency. Timed lyrics extraction from companion `.lrc` files or embedded audio tags (`USLT`, `LYRICS`) via Lofty. Features interactive line-seeking, smooth auto-follow highlighting with active verse scaling, overflow-safe wrapping, and an intelligent floating `Sync` pill when manual scrolling is detected.
  - **Live Playback Queue**: Full-height visual queue with one-click upcoming track removal (`✕`), seamless scroll preservation across deletions, and a dynamic floating `Locate` pill (`󰆤 X/Total`) that appears only when the active song is scrolled out of view.
  - **Sub-Tab Switching**: Toggleable Lyrics and Queue buttons with Cover Art as default resting state.
- **Persistent Speaker Indicator**: Active and playing tracks display a sleek, theme-accented speaker icon (``) overlaid directly on the album thumbnail with a contrast backdrop, keeping track title and artist columns consistently left-aligned with zero horizontal shifting.
- **Full Keyboard Navigation**:
  - Vim-style list navigation (`j`/`k`, `↓`/`↑`).
  - Playback transport controls (`Space` to toggle, `n`/`p` for next/prev, `←`/`→` for ±5s seek).
  - List selection and play with `Enter`.
  - Instant search focus with `/` and escape with `Esc`.
- **CLI Commands**:
  - `mixarchy-ctl queue`: Dump active playback queue and current track index.
  - `mixarchy-ctl queue-remove <index>`: Remove specific upcoming track from active queue.
  - `mixarchy-ctl play-index <index>`: Jump playback directly to track index in queue.
  - `mixarchy-ctl lyrics <id>`: Fetch synchronized/plain lyrics for track from `.lrc` or tags.

### Fixed
- **Queue Removal Scroll Jerk**: Eliminated visible scroll jumping on track deletion by preserving `contentY` across model resets and removing redundant delegate recentering.
- **Remove Button Hover Styling**: Replaced high-contrast red rectangle with subtle, theme-integrated `BorderSurface` utilizing `Style.hoverFillFor`, `Commons.Color.accent`, and `Border.controlSpec`.
- **Focused Lyrics Line Overflow**: Fixed GPU scale transform (`scale: 1.20`) pushing long verses beyond panel boundaries by constraining text layout width to `availableWidth / 1.20` with `Text.Wrap`.
- **Bootstrap Reload Loop**: Hardened binary verification in `Panel.qml` and installer temp paths to eliminate Quickshell top-bar inotify flickering.

## [1.2.0] - 2026-09-14
- Initial release with HiRes bit-perfect playback, Lofty metadata indexing, Fisher-Yates shuffle, instant search, and zero-daemon architecture.
