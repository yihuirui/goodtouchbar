# Security policy

## Supported version

Security fixes are evaluated for the latest published release. The 0.2.0 / build 2 source package is still in preparation and has no published release yet; the 0.1.0 / build 1 preparation is retained in the changelog.

## Reporting a vulnerability

Please do not post exploitable details, proof-of-concept code, credentials, or private user data in a public issue.

Use the public repository's [Security page](https://github.com/yihuirui/goodtouchbar/security) and its **Report a vulnerability** private reporting option when available. Repository maintainers should enable private vulnerability reporting. If the option is not available, contact the maintainer through the private contact options on the `yihuirui` GitHub profile and ask for a private reporting channel without posting technical details publicly.

Include the affected version/commit, macOS version and architecture, impact, and minimal reproduction steps. Redact account names, local paths, session data, tokens, and machine identifiers. Please allow reasonable time to investigate and prepare a fix before public disclosure.

## Scope notes

The app uses private macOS Touch Bar and AppleSMC interfaces. Its optional WorkBuddy monitor connects to an unauthenticated loopback CDP endpoint and can retry the currently bound chat. The optional fan helper, available only during confirmed native Intel execution, runs with administrator privileges after explicit installation. Reports about unsafe command execution, local endpoint exposure, authorization checks, fan-control recovery, or sensitive-data handling are in scope.
