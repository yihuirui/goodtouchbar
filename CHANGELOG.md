# Changelog

User-visible changes for each release are listed here.

## 0.2.0 (build 2) — release preparation

This source package adds native Apple silicon support alongside Intel. It is still being prepared for its first public release; no release artifact has been published.

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
