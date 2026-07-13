# Contributing

Contributions are welcome.

## Development setup

Requirements:

- macOS 13 or newer
- Swift 5.9 or newer
- Deskflow for manual integration testing
- Xcode and a local Apple Development identity for the functional GUI manager

Build and check the project:

```sh
swift build -c release
xcodebuild -project "Deskflow ASM.xcodeproj" -scheme "Deskflow ASM" test
./tests/smoke.sh
```

Build the native manager bundle without installing it:

```sh
./scripts/build-manager-app.sh
```

For interactive development, open the checked-in Xcode project:

```sh
open "Deskflow ASM.xcodeproj"
```

Select the shared **Deskflow ASM** scheme and press `Command-R`. Xcode natively builds the app, core library, management helper, session supervisor, installer tool, and tests. It embeds and signs the helper executables through target dependencies and Copy Files phases.

The development app can be used for UI work. Management-helper registration still requires the canonical root-owned installation in `/Applications`; use `./scripts/install-manager-app.sh` before testing privileged lifecycle operations.

## Release signing

The release workflow reads these encrypted GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`: base64-encoded PKCS#12 identity and private key
- `MACOS_CERTIFICATE_PASSWORD`: PKCS#12 password
- `MACOS_CODESIGN_IDENTITY`: exact certificate SHA-1 fingerprint

The workflow imports the identity into a temporary keychain on each macOS runner and deletes that keychain after the artifact is built. When all three secrets are absent, it creates an ad-hoc signed build. A partial configuration fails the build instead of silently changing signatures.

The configured Apple Development identity provides consistent signatures for the bundled manager, helper, and supervisor, but it does not provide public Gatekeeper trust. The release remains unnotarized and can display a warning after download.

The smoke suite must not modify the installed LaunchAgents or a user's Deskflow configuration.

## Change guidelines

- Keep the default behavior CLI-only and user-scoped.
- Do not add automatic changes to Deskflow settings, certificates, or macOS privacy databases.
- Keep all waits and retries bounded.
- Preserve the initial active-session check as well as the activation/resignation notifications.
- Test installer and uninstaller changes with paths and account names containing punctuation.
- Document changes that require users to re-grant macOS permissions.
- Keep the privileged manager helper management-only; it must never launch Deskflow.
- Keep privileged requests typed and UID-based. Do not add arbitrary command, shell, path, or environment execution over XPC.
- Require client code-signing validation and administrator authorization for every privileged mutation.
- Treat the supervisor bundled inside the signed manager app as the only GUI installation payload.
- Keep manager-app upgrades on the fixed `/Applications` path and preserve the atomic exchange and rollback checks.
- Update `ManagerConstants.managerVersion` and `CFBundleShortVersionString` together whenever manager/helper compatibility changes.

Changes to switching behavior should include the manual two-user test results described in [tests/manual-fast-user-switching.md](tests/manual-fast-user-switching.md). Changes to the native manager or privileged lifecycle operations should also follow [tests/manual-gui-manager.md](tests/manual-gui-manager.md).
