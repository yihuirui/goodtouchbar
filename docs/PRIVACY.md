# Privacy and data handling

## Network behavior

goodtouchbar has no project-owned telemetry service enabled by default and does not send data to a goodtouchbar server. The app is not fully offline: WorkBuddy runs as a separate client and may contact its own service, and the optional OpenToken command-line tool has its own behavior and configuration. This project does not control or audit those clients' network traffic.

## Local information the app reads

Features that read local activity are opt-in or can be disabled in the app. To display status, goodtouchbar may inspect:

- recent Codex rollout JSONL files under `~/.codex/sessions` for quota windows and agent-speed information;
- WorkBuddy session/status files for activity, output-token counts, model names, and timestamps;
- an OpenToken CLI result or its local cache for token totals, if OpenToken is installed.

Parsing session JSONL means the app reads local conversation/event records, not only a separate quota database. Its display purpose is to derive aggregate activity and quota information; this does not make those files non-sensitive. Do not share session files or logs publicly. Quota information can lag behind the service because the local rollout record may not be updated immediately.

## WorkBuddy background monitor

The optional WorkBuddy monitor starts a Node.js 22+ process in your user session. To establish or update a channel it may launch or restart the international WorkBuddy app, inspect the local client process, and connect to its Chrome DevTools Protocol (CDP) endpoint at `127.0.0.1`. The monitor binds to one matching WorkBuddy page and the selected chat before acting. A retryable error may cause the monitor to activate the client's retry control. That sends another client request and can consume AI service usage.

The CDP endpoint has no authentication. goodtouchbar asks WorkBuddy to use a randomly selected loopback port and checks that the listener belongs to the expected app, but unauthenticated local debugging remains a security boundary. Other software running as your user may be able to inspect or interact with local endpoints. Stop monitoring when you no longer need it, and do not use the feature on a chat you did not intend to bind.

To avoid overlapping retries during an upgrade, the monitor checks the legacy lock at `~/Library/Application Support/WorkBuddyRetry/background.lock` before starting or binding a chat, and again immediately before an automatic retry click. It reads the lock's PID and checks whether the operating system reports that PID as alive. If so, the new binding/click is blocked. A missing lock or a missing, invalid, or no-longer-live PID is treated as no active legacy owner. If the lock cannot be read, the monitor fails closed and pauses rather than clicking. This check does not read the legacy configuration or status files, change or delete the old lock, or terminate the old process. Stop an old monitor through the older tool's own controls; do not remove its lock or kill a process to bypass this check.

## Local state and logs

Application settings and presets use `~/Library/Application Support/GoodTouchBar`. Local diagnostic logs may be written under `~/Library/Logs/GoodTouchBar` and by the optional system helper. Logs are intended for local troubleshooting and are not uploaded by goodtouchbar, but they may contain timestamps, event/error codes, process information, and paths. Inspect and redact them before sharing.

Fan control is a separate optional feature. The privileged helper is available only when the app confirms native Intel execution; it is not included or installed by the Apple silicon package. Its helper stores a restricted client policy and recovery state for its own operation. See [installation and removal](INSTALLATION.md); uninstall only through the app so the helper can attempt to restore automatic fan control.

## Permissions and private APIs

Global Touch Bar presentation and AppleSMC sensor access rely on private macOS interfaces. Behavior can change without notice. The fan helper requires administrator authorization only when you choose to install/update it. Do not grant unrelated permissions to make an unsupported machine work.

Sending play/pause requires macOS Accessibility permission to post a system-defined media event. goodtouchbar requests this permission only when you click the play/pause control. If permission is denied, it does not post the event and offers an Accessibility settings link in the controls panel. A successful event submission does not guarantee that a particular media player responds; playback has not been validated on a physical target Mac.

## Privacy choices

- Leave WorkBuddy monitoring stopped when it is not needed.
- Disable optional usage or speed items in the app if you do not want it to inspect local session records.
- Do not install the privileged fan helper unless you intend to test fan control.
- Review diagnostic material before attaching it to a public issue.
