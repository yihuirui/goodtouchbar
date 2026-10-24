# Design influences

goodtouchbar is an independent project. We reviewed these public projects for product and interaction ideas; their source code is not copied into goodtouchbar and they are not runtime dependencies.

| Project | Idea we studied | Boundary in goodtouchbar |
| --- | --- | --- |
| [MTMR](https://github.com/Toxblh/MTMR) | Portable layout presets and direct, understandable control actions. | Presets use a constrained `goodtouchbar-layout` schema. They do not accept inline scripts or arbitrary commands. |
| [Pock](https://github.com/pock/pock) | A clear way to arrange and manage Touch Bar items. | goodtouchbar uses its own built-in catalog and app settings; it does not load third-party executable widget bundles. |
| [HapticKey](https://github.com/niw/HapticKey) | A separate tool can use a trackpad actuator to provide tactile feedback for Touch Bar input. | HapticKey's haptic implementation is not integrated. goodtouchbar does not claim the Touch Bar panel vibrates or that trackpad haptics are available. |

The project combines those product observations with an existing, independently developed Touch Bar application codebase. It does not claim to reproduce the full behavior of MTMR, Pock, HapticKey, or BetterTouchTool. For the exact source-review scope and limitations, see the local research report used during development; the report and its reference-source checkout are not part of this release package.

Each upstream project's license remains specific to that project's code. See [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) for the separate Stats-derived code notice included here.
