# goodtouchbar

**Version 0.3.0 · build 3 · experimental preview**

goodtouchbar is an experimental macOS companion for Intel and Apple silicon Macs. It brings AI activity, selected system metrics, and everyday controls into a configurable menu and, on supported hardware, a Touch Bar. Touch Bar availability depends on the Mac model, not on whether the processor is Intel or Apple silicon. The source is maintained in the public repository; preview packages are distributed through GitHub Releases.

[GitHub repository](https://github.com/yihuirui/goodtouchbar) · [Releases](https://github.com/yihuirui/goodtouchbar/releases) · [简体中文](README.zh-CN.md) · [Hardware compatibility](docs/COMPATIBILITY.md) · [Build and CI](docs/BUILDING.md) · [Install and remove](docs/INSTALLATION.md) · [Privacy](docs/PRIVACY.md) · [Presets](docs/PRESETS.md) · [Design influences](docs/PROJECT-INFLUENCES.md)

## What it does

- **Status details:** left-click the main status item to view quota cards, today's token usage, AI status, and a compact system overview. The bottom toolbar stays visible while the content scrolls. Right-click, or choose More in the panel, to open the complete action menu. Retry and hardware actions keep their existing confirmation and capability checks.

- **System controls:** a single tap on the Touch Bar item opens a native controls panel; a long press toggles mute directly. The panel provides a main-output volume slider, mute, play/pause, and a list of running apps. Play/pause posts a system-defined macOS media event. Clicking it requires Accessibility permission; macOS prompts for access, and the panel offers a link to Accessibility settings if access is denied. A player may ignore the event, and playback response has not been validated on a physical target Mac.
- **AI activity:** displays Codex quota data read from recent local rollout records, optional token totals through OpenToken, agent output-speed estimates from recent local session events, and WorkBuddy activity. Codex rollout updates can lag, so quota values may be stale.
- **Optional WorkBuddy monitor:** can watch a specifically bound international WorkBuddy chat and retry a detected retryable error. A retry sends an action through the WorkBuddy client and may consume service usage. The monitor can relaunch WorkBuddy when it needs to establish its local debugging channel.
- **Touch Bar modes:** choose **Auto**, **On**, or **Off**. Auto is the default when no setting exists; it enables presentation for recognized supported models and stays menu-only for unsupported or unknown hardware. On cannot create a Touch Bar on a machine without one, and unsupported or unknown models remain menu-only; Off is menu-only. A mode change takes effect after restarting the app. The new `touchBarMode` preference takes precedence; a 0.1 `touchBarEnabled` value maps `true` to On and `false` to Off.
- **System status:** displays CPU, memory, pressure, and available temperature readings. On Apple silicon, CPU temperature is a system thermal-zone reading, not a physical-core temperature; some sensors may be unavailable.
- **Fan control:** the optional privileged helper is experimental and available only when goodtouchbar confirms native Intel execution. Physical fan writes have not been validated on a target machine. Apple silicon can show read-only fan data when available; the arm64 package does not contain or install the fan helper.
- **AI and System layouts:** built-in presets use `goodtouchbar-layout` schema v2 for separate Touch Bar and menu layouts. Schema v1 bar-only presets remain importable and migrate their layout to both. Presets cannot execute scripts, start automatic retry, or change fan settings.
- **Menu-only mode:** retains the menu-bar app, supported AI integrations, and system monitoring. Pomodoro does not start or appear by default in this mode.

The global Touch Bar presenter and hardware sensors use macOS private interfaces. Their behavior can change across macOS releases and machines. This project is not a stable, feature-complete replacement for BetterTouchTool (BTT). HapticKey-inspired research has **not** been integrated: goodtouchbar does not promise Touch Bar or trackpad haptic feedback.

### Layout illustration

This is a text-only example of possible item types, **not a screenshot or a promise about order or live values**:

```text
[AI quota] [Token usage] [WorkBuddy status] [CPU / memory] [Temperature] [System controls]
```

## Requirements

- A Mac with an Intel `x86_64` or Apple silicon `arm64` processor.
- macOS 13 or later.
- A recognized supported Mac model is required for Touch Bar presentation. Some Apple silicon models do have a Touch Bar: Apple lists it on the [13-inch MacBook Pro with M1 (2020)](https://support.apple.com/en-us/111893) and [13-inch MacBook Pro with M2 (2022)](https://support.apple.com/en-us/111869). This does not imply support or physical validation for every Apple silicon model. See [hardware compatibility](docs/COMPATIBILITY.md).
- For local builds: Xcode Command Line Tools and a Swift 5.9-or-newer toolchain.
- The base app does not require Node.js. Node.js 22 or later is needed for the WorkBuddy background monitor and the JavaScript checks in `scripts/test-public.sh`; it may also be required by your OpenToken installation. OpenToken itself is optional and is used only for its token totals.

## Build from source

On macOS, from the repository root:

```sh
TEST_ARCH=arm64 /bin/zsh scripts/test-public.sh
/bin/zsh build-app.sh --arch arm64 --no-open
```

For an Intel build, use `TEST_ARCH=x86_64` and `--arch x86_64`. For a native local build, select the architecture matching the Mac. Without an explicit architecture, tests and builds use the native architecture. Packages are written under `dist/` in architecture-specific locations; CI builds each target on a matching runner. By default, local packages are ad-hoc signed for validation; they are not Developer ID signed or notarized. See [build and CI](docs/BUILDING.md) for artifact paths and runner details, and [installation and removal](docs/INSTALLATION.md) before installing the optional helper.

## Privacy and security

goodtouchbar has no project-owned telemetry service enabled by default, and it does not send data to a goodtouchbar server. That does **not** make it an offline application: integrations can read local app data, launch or communicate with a local client, and the client itself may contact its AI service. The WorkBuddy debugging protocol listens on loopback without authentication; a random local port and chat binding reduce accidental targeting but do not remove that protocol risk. Automatic retry can send another request to the currently bound AI service.

Read the full [privacy and data handling notes](docs/PRIVACY.md) and [security reporting policy](SECURITY.md). Avoid sharing diagnostic logs or local status files without reviewing them first.

## Project status

The 0.3.0 / build 3 public test suites passed on this Apple silicon development Mac using native arm64 and x86_64 under Rosetta. Status-detail state, action-routing, accessibility and layout checks also passed. Screenshot previews use synthetic data; offscreen layout previews do not validate macOS vibrancy composition. Earlier 0.2.0 read-only sampling on an M1 Pro returned CPU/memory data, M1 CPU thermal-zone readings, and two fan RPM readings. This does not validate native Intel hardware. The 0.1.0 / build 1 preparation is retained in [CHANGELOG.md](CHANGELOG.md). Local checks and GitHub publication are separate statuses, and automated checks do not establish physical Touch Bar presentation, player response, sensor coverage, or fan-write behavior. M1/M2 Touch Bar model examples are based on Apple specifications, not hardware acceptance of this app. Packages are ad-hoc signed and not notarized; check the [Releases page](https://github.com/yihuirui/goodtouchbar/releases) for publication status.

## Contributing

Bug reports, focused improvements, and documentation updates are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Do not attach private session data, credentials, or unredacted logs to a public issue. Report security issues using [SECURITY.md](SECURITY.md).

## License

Original goodtouchbar contributions are offered under the MIT License; see [LICENSE](LICENSE). The Stats-derived AppleSMC portions retain their separate MIT attribution in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and [Licenses/Stats-MIT.txt](Licenses/Stats-MIT.txt). The project license does not automatically relicense third-party material.
