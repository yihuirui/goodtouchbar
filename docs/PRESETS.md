# Layout presets

goodtouchbar provides **AI** and **System** starting layouts. They are arrangements of built-in controls and supported thresholds, not executable plugin bundles.

## Import and export

- Use the app's preset controls to export the current layout to JSON or import a JSON preset.
- The current format is `goodtouchbar-layout`, schema version `2`, with separate `layout` (Touch Bar) and `menuLayout` fields plus supported `thresholds`.
- Schema version `1` remains supported by its legacy decoder. Its `layout` is migrated into both the Touch Bar and menu layouts; menu-only mode then reads `menuLayout`.
- Import validates the version and accepted fields before saving. Keep an exported copy of your current layout before importing a different one.
- Presets contain layouts and supported thresholds only. They cannot run shell scripts, import executable plugins, enable WorkBuddy automatic retry, or change fan-control state.
- Unknown or unsupported schema versions should be rejected. Do not edit an exported version field to bypass validation.

An AI layout is a convenient arrangement for quota, token, and agent activity items. A System layout emphasizes metrics and system controls. Names describe layout intent; they do not make local account data part of the preset. The JSON should contain configuration only. Review a file from another person before importing it.

Presets are separate from application configuration and the previous BestTouchTool settings directory. goodtouchbar does not migrate, read, or overwrite that product's existing user configuration.
