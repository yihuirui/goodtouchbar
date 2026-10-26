# Design influences

goodtouchbar is an independent project. We reviewed these public projects for product and interaction ideas; their source code is not copied into goodtouchbar and they are not runtime dependencies.

| Project | Idea we studied | Boundary in goodtouchbar |
| --- | --- | --- |
| [MTMR](https://github.com/Toxblh/MTMR) | Portable layout presets and direct, understandable control actions. | Presets use a constrained `goodtouchbar-layout` schema. They do not accept inline scripts or arbitrary commands. |
| [Pock](https://github.com/pock/pock) | A clear way to arrange and manage Touch Bar items. | goodtouchbar uses its own built-in catalog and app settings; it does not load third-party executable widget bundles. |
| [HapticKey](https://github.com/niw/HapticKey) | A separate tool can use a trackpad actuator to provide tactile feedback for Touch Bar input. | HapticKey's haptic implementation is not integrated. goodtouchbar does not claim the Touch Bar panel vibrates or that trackpad haptics are available. |

The project combines those product observations with an existing, independently developed Touch Bar application codebase. It does not claim to reproduce the full behavior of MTMR, Pock, HapticKey, or BetterTouchTool. For the exact source-review scope and limitations, see the local research report used during development; the report and its reference-source checkout are not part of this release package.

Each upstream project's license remains specific to that project's code. See [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) for the separate Stats-derived code notice included here.

## Design-guided status details refinement

The 0.3.1 status details refinement uses design guidance from [Hallmark](https://github.com/Nutlope/hallmark) (v2.0.0, commit `7ec868225c6caa040558c321ee0fefa0e73f83a8`, MIT) and [Impeccable](https://github.com/pbakaus/impeccable) (v4.7.1, commit `3671d50f0ac9a662ce0615e85a256110c9cd720b`, Apache-2.0).

We applied their principles of clear hierarchy, restrained grouping, readable status text, honest empty states, and controls that name their actions. The application remains native AppKit with system typography and SF Symbols. The tools and reference checkouts are development-only; they are not bundled, imported, or runtime dependencies, and no upstream application code is copied into goodtouchbar.

Hallmark's automated checks target web interfaces. Impeccable's native audit material covers iOS, Android and adaptive interfaces; neither tool establishes macOS AppKit audit coverage. We validate this refinement with the project's native state, action-routing, accessibility and layout checks. Synthetic offscreen previews help assess layout but do not verify macOS vibrancy composition or physical hardware behavior.
