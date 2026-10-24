# Install, update, remove, and roll back

## Install

goodtouchbar 0.2.0 provides separate `x86_64` Intel and `arm64` Apple silicon packages for macOS 13 or later. The app is menu-only on unsupported or unknown Mac models. See [hardware compatibility](COMPATIBILITY.md) for the initial Touch Bar model allowlist and Auto/On/Off behavior.

1. Build from reviewed source in the [public repository](https://github.com/yihuirui/goodtouchbar), or check the [Releases page](https://github.com/yihuirui/goodtouchbar/releases) for a future official artifact. No release download is published yet.
2. Move `goodtouchbar.app` to `/Applications`.
3. Open the app and check its status panel. If macOS reports that the app cannot be verified, remember that local builds are ad-hoc signed and not notarized. Do not override Gatekeeper for an artifact you do not trust; building from source is the available review path.
4. The optional fan helper is not required for the app, system controls, read-only sensors, or AI status. It is available only when the app confirms it is running natively on Intel. Apple silicon packages do not include or install the helper; Apple silicon fan readings are read-only when available. On supported Intel hardware, install the helper only if you intend to try experimental fan control. Use the app's fan-control screen to install or update it; macOS will ask for administrator authorization. The helper is bound to the installed app's code signature. Do not run the installer script yourself with `sudo`.
5. Node.js 22 or later is needed only when using WorkBuddy background monitoring. OpenToken is optional and is needed only for its token-total integration.

Touch Bar presentation and SMC sensor access use private macOS interfaces. Availability can vary by OS version and hardware, and automated build checks do not prove that the global Touch Bar is visible on a particular Mac. The app status/health screen is the first place to check when an item does not appear.

Touch Bar mode defaults to **Auto** when no preference is saved. A saved 0.1 `touchBarEnabled` preference maps `true` to **On** and `false` to **Off**; an explicit `touchBarMode` value takes precedence. Mode changes take effect after restarting the app. **On** cannot make Touch Bar hardware available on a model that lacks it.

## First-use authorization

- **Fan helper:** installing or updating the helper changes system-level files and registers a privileged background service. Approve the macOS administrator prompt only when you explicitly choose that action. The app does not require helper installation for normal use or read-only sensors.
- **Play/pause:** clicking this control sends a system-defined macOS media event and requires Accessibility permission. goodtouchbar requests permission when you click; if it is denied, no event is sent and the controls panel provides a link to Accessibility settings. This is separate from volume, mute, and app switching.
- **Other macOS access:** grant a system permission only if the OS or a feature you choose requests it and you understand why. Permission availability and prompt wording can differ by macOS version. The app does not need permission to read private AI account credentials.
- **WorkBuddy monitoring:** use the monitor controls only for the chat you intend to watch. The monitor targets the currently bound international WorkBuddy chat and can retry an eligible error through the client. See [Privacy](PRIVACY.md) before enabling it.

If a permission prompt is cancelled, the affected integration may remain unavailable; the rest of the app can still be used. Reopen the relevant feature from the app when you are ready to authorize it.

### Upgrading while an older retry monitor may be running

Before starting/rebinding a WorkBuddy chat and immediately before each automatic retry click, goodtouchbar reads only the legacy lock file at `~/Library/Application Support/WorkBuddyRetry/background.lock` and checks whether the recorded PID is reported alive by the operating system. If so, the new binding/click is blocked. A missing lock or a missing, invalid, or no-longer-live PID is treated as no active legacy owner. If the lock cannot be read, goodtouchbar pauses instead of sending a click. It does not read old configuration/status files, change or remove the lock, or terminate the old process. If the check blocks, stop monitoring in the older tool and retry from goodtouchbar. Do not delete the lock or kill a process to bypass the check.

## Update

1. Export the current layout preset and keep a copy of any local configuration you care about.
2. Stop an active WorkBuddy monitor and restore automatic fan control before replacing the app.
3. Replace `/Applications/goodtouchbar.app` with the new build and reopen it.
4. If fan control reports a helper version or signature mismatch, use the app's **Install / Update Helper** action. The privileged helper is intentionally bound to the exact app build.

## Remove

1. Stop WorkBuddy monitoring from the app.
2. If the fan helper is installed, first request **Automatic** fan control and confirm that the app reports automatic control. Then use the app's **Uninstall Helper** action. The uninstaller attempts to restore automatic mode and retains recovery material if it cannot confirm safe removal. If recovery fails, stop and follow the app's diagnostic instructions; do not delete system recovery files by hand.
3. Quit goodtouchbar and remove `/Applications/goodtouchbar.app`.
4. App settings and presets are stored under `~/Library/Application Support/GoodTouchBar`. Remove that directory only if you also want to delete those local settings. Review or export anything you want to keep first. Local logs are separate and are not removed by the helper uninstaller.

## Roll back

Keep the previous app bundle and an exported preset before updating. To roll back, stop monitoring, restore automatic fan control, replace the app with the previous build, and reopen it. If the helper was updated, reinstall/update it from the restored app so the helper's signature policy matches. A configuration migration or preset schema change may prevent an older build from reading newer settings; keep the exported preset and do not delete the original backup until the older build is confirmed usable.
