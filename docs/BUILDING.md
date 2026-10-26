# Build and CI

goodtouchbar 0.3.1 builds separate native `x86_64` and `arm64` macOS 13+ application packages; these are not a universal binary. Each architecture is tested and packaged on a matching macOS runner; cross-compilation is not used as evidence that a target architecture works.

## Local build

Use macOS with Xcode Command Line Tools and Swift 5.9 or newer. Node.js 22 or newer is needed for the public JavaScript regression checks and for the optional WorkBuddy monitor. OpenToken remains optional.

Run the public checks and create the package for the architecture you intend to run:

```sh
TEST_ARCH=x86_64 /bin/zsh scripts/test-public.sh
/bin/zsh build-app.sh --arch x86_64 --no-open
```

On Apple silicon, use `arm64`:

```sh
TEST_ARCH=arm64 /bin/zsh scripts/test-public.sh
/bin/zsh build-app.sh --arch arm64 --no-open
```

Without an explicit test architecture, `scripts/test-public.sh` uses the native architecture. Its supported overrides are `TEST_ARCH=arm64|x86_64` or `TARGET_TRIPLE`. `build-app.sh` accepts `--arch arm64|x86_64` and defaults to the native architecture. Expected outputs are:

- App bundle under `dist/0.3.1/arm64/` or `dist/0.3.1/x86_64/`.
- `dist/goodtouchbar-0.3.1-arm64.zip` or `dist/goodtouchbar-0.3.1-x86_64.zip`.
- A `.sha256` sidecar alongside each ZIP.
- `dist/goodtouchbar-0.3.1-{arch}-build-manifest.txt` for each target architecture.

Builds without a Developer ID identity are ad-hoc signed, not Developer ID signed or notarized. This CI workflow supplies no signing identity and does not notarize its artifacts.

## GitHub Actions

The CI matrix runs each target natively: Intel on `macos-15-intel`, Apple silicon on `macos-15`. Each job checks its runner architecture, installs Node.js 22 for JavaScript checks, runs `scripts/test-public.sh` with `TEST_ARCH` set to the matrix architecture, and builds the matching app package. The workflow grants `contents: read` only. It does not publish a release or use signing credentials. A manual `workflow_dispatch` run uploads separate, architecture-named artifacts for seven days.

GitHub lists `macos-15-intel` as a standard Intel runner and `macos-15` as a standard M1 arm64 runner; the latter is currently marked public preview. Standard GitHub-hosted runners are free and unlimited for public repositories. For private repositories, macOS runner usage draws from the plan's included minutes and is billed after those minutes are exhausted. Larger macOS runners are a separate paid option and are not used by this workflow. Confirm current runner availability and billing in [GitHub's runner selection documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job) and [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing) before enabling Actions in a repository with access restrictions.

CI artifacts and passing automated checks do not establish physical Touch Bar presentation, player media-key response, temperature coverage, or fan-write behavior. See [hardware compatibility](COMPATIBILITY.md) before treating a machine as validated.
