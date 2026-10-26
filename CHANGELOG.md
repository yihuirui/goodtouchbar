# Changelog

User-visible changes for each release are listed here.

## 0.3.0 (build 3) — experimental preview

- Replace the primary status-item text menu with a native details popover: separate five-hour and weekly quota cards, today's token usage, AI state, and a compact system overview.
- Keep the complete action menu accessible with a right click and the details panel's More entry; group diagnostics separately from everyday actions.
- Use existing monitoring snapshots for presentation; opening the panel does not start WorkBuddy retry or install a fan helper.
- Retain menu-only and Touch Bar modes, Apple silicon read-only fan policy, and separate native packages.

## 0.2.0 (build 2) — experimental preview

Released as an [experimental preview](https://github.com/yihuirui/goodtouchbar/releases/tag/v0.2.0), with native Apple silicon support alongside Intel.

- Add Auto, On, and Off Touch Bar modes with model allowlist detection and conservative menu-only behavior for unsupported or unknown models.
- Add Apple silicon CPU, memory, thermal-zone, AI activity, and menu-only support; keep fan readings read-only and omit the fan helper from arm64 packages.
- Add separate Touch Bar and menu layouts in `goodtouchbar-layout` schema v2 while retaining schema v1 import compatibility.
- Prepare separate native `x86_64` and `arm64` packages and CI jobs.

Automated checks do not establish physical Touch Bar presentation, player response, Apple silicon sensor coverage, or fan-write validation. See [README.md](README.md) for current release boundaries.

## 0.1.0 (build 1) — release preparation

This source package is being prepared for its first public release. No release artifact has been published.

- Prepare AI and System layout presets with the `goodtouchbar-layout` schema v1.
- Add a native system-controls panel for output volume, mute, play/pause, and app switching.
- Keep AI quota, optional token usage and output-speed estimates, WorkBuddy status/retry, system metrics, and experimental Intel fan control in clearly separated feature areas.
- Begin preparing an Intel `x86_64` macOS 13+ build and public contribution/security documentation.

This entry describes the 0.1.0 release target; automated checks do not establish real Touch Bar, OS-compatibility, or fan-write validation. See [README.md](README.md) for current release boundaries.
