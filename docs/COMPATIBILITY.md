# Hardware and display modes

goodtouchbar 0.3.0 targets Intel `x86_64` and Apple silicon `arm64` Macs running macOS 13 or later. A Mac's CPU architecture does not tell you whether it has a Touch Bar. Apple lists the Touch Bar on the [13-inch MacBook Pro with M1 (2020)](https://support.apple.com/en-us/111893) and the [13-inch MacBook Pro with M2 (2022)](https://support.apple.com/en-us/111869), among other models. This is evidence that Apple silicon and Touch Bar can coexist; it is not a compatibility guarantee for every Apple silicon Mac.

The initial Touch Bar model allowlist uses these `hw.model` identifiers: `MacBookPro13,2`, `MacBookPro13,3`, `MacBookPro14,2`, `MacBookPro14,3`, `MacBookPro15,2`, `MacBookPro15,3`, `MacBookPro15,4`, `MacBookPro16,1`, `MacBookPro16,2`, `MacBookPro16,3`, `MacBookPro16,4`, `MacBookPro17,1`, and `Mac14,7`. The last two correspond to the M1 and M2 13-inch MacBook Pro families; Apple’s specifications confirm those machines have a Touch Bar. The app checks model identity and architecture metadata; CPU architecture alone does not decide Touch Bar support. The allowlist may not include every Mac with Touch Bar hardware.

The app selects Touch Bar behavior by its supported model allowlist and architecture metadata, not by architecture alone. The setting offers three modes:

- **Auto** (default when no saved mode exists): enable Touch Bar presentation for a recognized supported model; use menu-only mode for a recognized model without Touch Bar support and for unknown hardware. The app can distinguish these two reasons.
- **On**: request Touch Bar presentation only when the model is supported. It cannot create Touch Bar hardware; unsupported hardware remains menu-only with an explanation.
- **Off**: use menu-only mode.

Changing the mode takes effect after restarting goodtouchbar. Hardware detection and global Touch Bar presentation are separate: a recognized model may still report a presenter/private-API error, which does not mean the model lacks a Touch Bar.

The saved preference key `touchBarMode` takes precedence. For settings written by version 0.1, the legacy `touchBarEnabled` value maps `true` to **On** and `false` to **Off**. If neither setting exists, the app uses **Auto**.

## Menu-only behavior

Menu-only mode keeps goodtouchbar available from the menu bar and supports the Apple silicon monitoring and AI integrations present in this release. It does not start the Pomodoro timer or show a Pomodoro item by default.

CPU temperature display on Apple silicon is based on available system thermal-zone readings; it is not a per-physical-core temperature measurement. A sensor can be unavailable on a given model and display `--`. Apple silicon temperature readings have not been validated across M2/M3 hardware.

Fan behavior differs by architecture:

- **Intel:** the optional privileged fan helper remains experimental; physical fan writes are not validated by automated tests.
- **Apple silicon:** fan readings are read-only when available. The arm64 app does not include or install the fan helper and cannot write fan targets.

Unit tests with injected model metadata and simulated sensors are not hardware acceptance. The M1/M2 Touch Bar Mac models listed above have not been physically tested with this release. Touch Bar visibility, actual sensor coverage, and hardware-specific behavior still need testing on each target family. Running the app under Rosetta has not been physically validated for Touch Bar presentation.
