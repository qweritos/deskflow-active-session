# Contributing

Contributions are welcome.

## Development setup

Requirements:

- macOS 13 or newer
- Swift 5.9 or newer
- Deskflow for manual integration testing

Build and check the project:

```sh
swift build -c release
./tests/smoke.sh
```

The smoke suite must not modify the installed LaunchAgents or a user's Deskflow configuration.

## Change guidelines

- Keep the default behavior CLI-only and user-scoped.
- Do not add automatic changes to Deskflow settings, certificates, or macOS privacy databases.
- Keep all waits and retries bounded.
- Preserve the initial active-session check as well as the activation/resignation notifications.
- Test installer and uninstaller changes with paths and account names containing punctuation.
- Document changes that require users to re-grant macOS permissions.

Changes to switching behavior should include the manual two-user test results described in [tests/manual-fast-user-switching.md](tests/manual-fast-user-switching.md).
