# deskflow-active-session

Run the Deskflow CLI server only for the active macOS desktop session.

When Fast User Switching moves an account into the background, this utility stops that account's `deskflow-core` server. When the account becomes active again, it starts the server with that user's normal Deskflow configuration.

There is no TCP proxy, system daemon, or Deskflow GUI process. Inactive accounts retain only a lightweight per-user supervisor.

## Requirements

- macOS 13 or newer
- Deskflow installed in `/Applications/Deskflow.app`
- Deskflow configured as a server in every participating account
- Administrator access during installation
- A Swift toolchain when building from source

The initial implementation was tested on macOS 15.7.8 with Deskflow 1.26.0 on Intel. It builds natively on the Mac running the installer.

## Install

First, sign into every participating account, configure Deskflow as a server, then quit its GUI and disable any separate Deskflow login item.

Build and install agents for the accounts:

```sh
git clone https://github.com/qweritos/deskflow-active-session.git
cd deskflow-active-session
./scripts/install.sh alice alice-work
```

The installer requests administrator access, compiles and ad-hoc signs one shared supervisor, then installs a LaunchAgent for each named account. Run the same command to upgrade.

Validate the build, account lookup, signature, and generated plist without installing:

```sh
./scripts/install.sh --dry-run alice alice-work
```

A custom Deskflow installation is supported through an environment variable:

```sh
DESKFLOW_CORE=/custom/path/deskflow-core ./scripts/install.sh alice alice-work
```

## macOS permissions

The helper launches `deskflow-core`, so macOS may attribute input-access requests to the helper rather than to the Deskflow GUI. Add this exact installed binary to **System Settings → Privacy & Security → Accessibility** and **Input Monitoring** if prompted:

```text
/usr/local/libexec/deskflow-session-supervisor
```

Local builds use a stable ad-hoc designated identifier at a root-protected path. A first migration from a differently signed build—or some macOS updates—can still leave an old permission toggle looking enabled while macOS rejects the installed binary. If that happens:

1. Remove the old helper entry from the privacy list.
2. Add the exact installed path again. Press `Command-Shift-G` in the file picker to enter it.
3. Enable the new entry.
4. Restart the supervisor or log out and back in.

The installer never modifies the macOS privacy database.

For distributed builds, set `CODESIGN_IDENTITY` to a Developer ID Application identity. Developer ID signing and notarization are preferable to local ad-hoc signing.

## Deskflow configuration

With no override, the supervisor runs:

```sh
/Applications/Deskflow.app/Contents/MacOS/deskflow-core server
```

Deskflow therefore loads each user's default settings and server layout:

```text
~/Library/Deskflow/Deskflow.conf
~/Library/Deskflow/deskflow-server.conf
```

The installer does not copy or alter user configuration, screen layouts, certificates, or TLS keys. Screen placement can intentionally differ between accounts, so confirm the configured exit edge in each layout.

The supervisor also supports optional command-line overrides:

```text
--core PATH
--settings PATH
--activation-delay SECONDS
--stop-timeout SECONDS
```

Run `deskflow-session-supervisor --help` for the complete interface.

## Status and restart

```sh
./scripts/status.sh alice alice-work
```

Expected state:

```text
USER                   SUPERVISOR   SERVER       EXPECTED
alice                  running      running      running
alice-work             running      stopped      stopped
```

Only the active console user should own Deskflow's listening port.

Restart the active account, or name one explicitly:

```sh
./scripts/restart.sh
./scripts/restart.sh alice
```

Logs are stored per user:

```text
~/Library/Logs/Deskflow/active-session.out.log
~/Library/Logs/Deskflow/active-session.err.log
```

## Uninstall

Remove selected accounts:

```sh
./scripts/uninstall.sh alice alice-work
```

To explicitly discover and remove all agents installed under local user accounts:

```sh
./scripts/uninstall.sh --all
```

It does not remove Deskflow, user configuration, certificates, logs, or macOS privacy decisions.

## How it works

Each participating account runs the same Aqua LaunchAgent. The native supervisor:

1. Observes macOS session-active and session-inactive notifications.
2. Confirms that its desktop is the current console session.
3. Starts `deskflow-core server` only for that active user.
4. Sends `TERM` when the desktop becomes inactive.
5. Uses `KILL` after four seconds if Deskflow does not stop.
6. Retries with bounded exponential backoff if the shared port is temporarily unavailable.

The supervisor stays inside each user's GUI bootstrap session, so Deskflow receives the correct home directory, WindowServer context, and default settings. A root LaunchDaemon must not run Deskflow itself.

## Limitations

- Fast User Switching briefly interrupts the remote client while the server changes users.
- Deskflow's GUI must remain closed or it may compete for the CLI server.
- Every user needs a valid server layout and macOS input permissions.
- The login window, SSH sessions, and non-console sessions are not served.
- A forced shutdown can leave the port unavailable briefly; the supervisor retries automatically.
- Full Fast User Switching behavior requires manual testing on a two-user Mac.
- Ad-hoc local signatures do not provide permission continuity across changed builds. A distributed release should use a stable Developer ID signature and notarization.

## Development

Build and run smoke checks without installing:

```sh
make build
make check
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [tests/manual-fast-user-switching.md](tests/manual-fast-user-switching.md).

## License

This project is available under the [MIT License](LICENSE).

Deskflow is a separate project and is not bundled, linked, or redistributed here. This utility is independent and is not an official Deskflow project.
