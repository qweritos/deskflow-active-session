# GUI manager

The optional **Deskflow Active Session Manager** is a native macOS app for installing the supervisor, checking every participating account, restarting a supervisor, and uninstalling selected accounts.

It does not launch the Deskflow GUI. Each active account still runs only:

```text
deskflow-session-supervisor → deskflow-core server
```

## Build and install

Release DMGs contain **Deskflow ASM.app** and an **Applications** shortcut for
drag-and-drop installation. Intel (`x86_64`) and Apple-silicon (`arm64`) builds
are published separately. CI uses the repository's Apple Development signing
identity when configured and otherwise falls back to an ad-hoc signature. The
DMGs are not notarized, so redistributed downloads can display a Gatekeeper
warning.

Source builds require full Xcode and a usable Apple Development or Developer ID signing identity:

```bash
security find-identity -v -p codesigning
```

Build, sign, copy the app to `/Applications`, and open it:

```bash
./scripts/install-manager-app.sh
```

Quit the manager in every logged-in user session before running the installer.
The installer stages a root-owned copy in its protected system state directory,
verifies its signature and embedded payloads, then atomically exchanges it with
the current app on the same filesystem. The previous app remains available for
rollback until final verification and helper health checks succeed. A durable
renewal journal restores an interrupted management-helper update on the next
installer run.

An existing management-helper registration is renewed after promotion, as
required when its embedded executable changes. With the same signing identity,
macOS retains the existing Background Items approval. If the signing identity
changes and the helper cannot be registered, the installer rolls back; remove
the management helper with the old app, rerun the installer, and select **Set Up
Helper** again.

The build automatically uses the first available Apple Development signing identity. Select one explicitly when needed:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/install-manager-app.sh
```

Build without copying the app:

```bash
./scripts/build-manager-app.sh
open ".build/Deskflow ASM.app"
```

Or open `Deskflow ASM.xcodeproj`, select the shared **Deskflow ASM** scheme,
and use **Run**. Xcode natively builds, embeds, signs, and launches the app and
its helper executables. Use the source installer when testing helper
registration or other privileged operations that require the canonical
root-owned `/Applications/Deskflow ASM.app` location.

Set `ARCHS` to build more than one architecture:

```bash
ARCHS="x86_64 arm64" ./scripts/build-manager-app.sh
```

Apple Development and ad-hoc builds lack public Gatekeeper trust, and the helper requires the app to be installed root-owned by the source installer. Developer ID signing and notarization are required to distribute without a Gatekeeper warning. The source build scripts do not notarize or staple the app.

If verification reports `CSSMERR_TP_CERT_REVOKED`, renew the Apple Development
certificate in **Xcode → Settings → Accounts → Manage Certificates**, then
rebuild. Do not bypass the installer signature checks.

## First setup

1. Open the manager from `/Applications`.
2. Select **Set Up Helper**.
3. If macOS requests approval, open **System Settings → General → Login Items** and enable the manager under **Allow in the Background**.
4. Return to the manager. It checks automatically; select **Check Again** if needed.
5. Select the local accounts that should participate.
6. Select **Install / Upgrade** and authenticate as an administrator.

The account list uses local numeric user IDs internally. Hidden accounts, service accounts, and accounts with a disabled login shell cannot be newly installed. An ineligible account with an existing managed installation remains visible for restart or cleanup.

## Operations

- **Refresh** reads installation, GUI-session, supervisor, Deskflow server, and TCP port status without an administrator prompt.
- **Install / Upgrade** installs the sealed supervisor bundled with the app and creates a LaunchAgent for each selected account. A shared supervisor upgrade briefly restarts every currently managed account, including unselected accounts.
- **Restart** restarts selected installed supervisors. Background users remain in standby with no Deskflow server.
- **Uninstall** removes the selected LaunchAgents. Removing the final managed account also removes the shared supervisor binary. Deskflow configuration, certificates, TLS keys, logs, and macOS privacy decisions remain untouched.
- **Remove Management Helper** unregisters only the management service. Existing user LaunchAgents continue working.

Changing an account checkbox does nothing until an operation button is selected.

## Supported configuration

The GUI manages the standard installation shape only:

```text
/Applications/Deskflow.app/Contents/MacOS/deskflow-core
default per-user Deskflow settings
TCP port 24800
default activation and stop timings
```

Use the CLI scripts for `DESKFLOW_CORE`, `--settings`, custom timing values, custom LaunchAgent arguments, or a non-default Deskflow port. The GUI reports a manually customized managed LaunchAgent as invalid and refuses to replace it.

## Upgrade or remove the manager app

To upgrade, rerun `./scripts/install-manager-app.sh`. If the app reports that its registered helper is older or unreachable, select **Repair / Update Helper**.

For complete GUI removal:

1. Use **Uninstall** for every managed account if the session supervisor is no longer needed.
2. Select **Remove Management Helper**.
3. Quit the manager and delete `/Applications/Deskflow ASM.app`.

Removing the manager does not delete Deskflow settings, certificates, TLS keys, logs, or macOS privacy decisions.

## macOS input permissions

The manager cannot grant or inspect another process's macOS privacy authorization. Accessibility and Input Monitoring must target the installed supervisor:

```text
/usr/local/libexec/deskflow-session-supervisor
```

Replacing an older differently signed supervisor may require removing the old privacy entry and adding this exact path again, even if its existing toggle still looks enabled.

## Security model

The app uses [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) to register an on-demand management-only LaunchDaemon. The helper:

- accepts only a small typed XPC interface;
- verifies that its client matches the manager app's code-signing requirement;
- requires a fresh `system.privilege.admin` authorization for mutations;
- resolves local user IDs itself instead of trusting paths from the GUI;
- installs only the sealed supervisor bundled with the signed app;
- never executes `deskflow-core` directly and never receives Accessibility or Input Monitoring access;
- never edits the macOS privacy database.

The existing shell scripts remain available as a headless fallback and do not depend on the GUI manager.
