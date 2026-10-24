# Contributing

Thanks for considering a contribution. This project targets Intel `x86_64` and Apple silicon `arm64` Macs running macOS 13 or later. Touch Bar availability depends on the Mac model, not CPU architecture. Hardware-specific and private-API behavior needs particular care; see [hardware compatibility](docs/COMPATIBILITY.md).

## Before opening an issue or pull request

- Search existing issues for the same problem.
- For a bug, include the goodtouchbar version/build, Mac architecture, macOS version, expected result, and concise reproduction steps.
- Never attach credentials, private session files, tokens, full user directories, or unredacted diagnostics to a public issue. Share only the minimum information needed.
- Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Development checks

On macOS with Xcode Command Line Tools, Swift 5.9 or newer, and Node.js 22 or newer for JavaScript checks:

```sh
TEST_ARCH=arm64 /bin/zsh scripts/test-public.sh
/bin/zsh build-app.sh --arch arm64 --no-open
```

Use `TEST_ARCH=x86_64` and `--arch x86_64` for the Intel package. Both scripts default to native architecture when no override is provided. The public packages are separate architecture builds, not a universal binary. CI uses matching Intel and Apple silicon runners with `contents: read`; a manually dispatched run saves architecture-specific artifacts and does not publish a release. A successful build or automated check is not evidence of physical Touch Bar presentation, player response, or real fan-write behavior.

Build identifiers: the Swift package and main executable are `GoodTouchBar`; the read-only sensor executable is `GoodTouchSensors`; the privileged fan service is `GoodTouchFanHelper` and is packaged only for confirmed native Intel execution. The app bundle ID is `io.github.yihuirui.goodtouchbar` and the fan helper service ID is `io.github.yihuirui.goodtouchbar.fan-helper`. Per-user app state belongs under `~/Library/Application Support/GoodTouchBar`.

## Pull requests

- Keep changes focused and describe user-visible behavior and limitations.
- Add or update checks for changes where practical; never route around a failing safety or validation check.
- Do not add arbitrary command execution to preset import. The `goodtouchbar-layout` schema is for layout and thresholds only; fan control and WorkBuddy retry are separate features.
- Call out private macOS API use, filesystem access, network behavior, permission changes, and system-service changes in the pull request description.
- Do not include generated build products, credentials, local logs, or real user data.
- Preserve third-party copyright and license notices for any newly added external material. Ask before adding a new runtime dependency.

By submitting a contribution, you agree that your original contribution is offered under the repository's MIT License. This does not relicense third-party material.
