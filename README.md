<div align="center">
  <h1><img alt="Deskflow" height="48" src="https://avatars.githubusercontent.com/u/181782356?s=200&v=4" /> deskflow-active-session</h1>
  <p>Deskflow across macOS user sessions <br /> Share one Mac's keyboard and mouse regardless of which account is active</p>
</div>

<p align="center">
  <a href="https://github.com/qweritos/deskflow-active-session/releases"><img alt="Release" src="https://img.shields.io/github/v/release/qweritos/deskflow-active-session?style=flat-square" /></a>
  <a href="https://github.com/qweritos/deskflow-active-session/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/qweritos/deskflow-active-session?style=flat-square" /></a>
  <a href="https://github.com/qweritos/deskflow-active-session/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/qweritos/deskflow-active-session?style=flat-square" /></a>
  <a href="https://github.com/qweritos/deskflow-active-session/forks"><img alt="Forks" src="https://img.shields.io/github/forks/qweritos/deskflow-active-session?style=flat-square" /></a>
  <a href="https://github.com/qweritos/deskflow-active-session/issues"><img alt="Issues" src="https://img.shields.io/github/issues/qweritos/deskflow-active-session?style=flat-square" /></a>
  <a href="https://github.com/qweritos/deskflow-active-session/commits/main"><img alt="Last Commit" src="https://img.shields.io/github/last-commit/qweritos/deskflow-active-session?style=flat-square" /></a>
</p>

<br />

## Why

- Keep the keyboard and mouse connected to a shared Mac available to another computer after Fast User Switching.
- Run the Deskflow CLI server only for the foreground macOS desktop session.
- Preserve each account's default Deskflow configuration, screen layout, certificates, and TLS keys.
- Avoid a TCP proxy, root daemon, or always-running Deskflow GUI.

macOS keeps background desktop sessions and their processes alive. Running Deskflow as a login item for every user can therefore leave multiple servers competing for TCP port 24800 and macOS input permissions.

`deskflow-active-session` keeps a lightweight supervisor in each participating GUI session. It stops that user's `deskflow-core` server when the session moves into the background and starts it again when the session becomes active.

## Install

### Prerequisites

Before installing:

- Use macOS 13 or newer.
- Make sure every participating account is a local GUI user.
- Have administrator access for the shared binary and per-user LaunchAgents.

Install the Xcode Command Line Tools, which provide the Swift toolchain used to build the supervisor:

```bash
xcode-select --install
swift --version
```

Install Deskflow with Homebrew:

```bash
brew tap deskflow/tap
brew install deskflow
```

Alternatively, install the app from the [official Deskflow releases](https://github.com/deskflow/deskflow/releases).

Confirm that the Deskflow CLI core is available:

```bash
test -x /Applications/Deskflow.app/Contents/MacOS/deskflow-core
```

Finally, sign into every participating account and:

- Open Deskflow once.
- Configure it in server mode and save the screen layout.
- Quit the GUI and disable any separate Deskflow login item.

### Install the supervisor

Clone the repository and name every participating account:

```bash
git clone https://github.com/qweritos/deskflow-active-session.git
cd deskflow-active-session
./scripts/install.sh alice alice-work
```

The installer requests administrator access, builds and ad-hoc signs one shared supervisor, then installs a LaunchAgent for each named account. Run the same command again to upgrade.

### Install options

Validate the build, account lookup, signature, and generated plist without installing:

```bash
./scripts/install.sh --dry-run alice alice-work
```

Use a custom Deskflow installation path:

```bash
DESKFLOW_CORE=/custom/path/deskflow-core ./scripts/install.sh alice alice-work
```

## macOS permissions

The helper launches `deskflow-core`, so macOS may attribute input-access requests to the helper instead of the Deskflow GUI. Add this exact installed binary to **System Settings → Privacy & Security → Accessibility** and **Input Monitoring** if prompted:

```text
/usr/local/libexec/deskflow-session-supervisor
```

> **Important:** Enabling only the Deskflow GUI may leave the CLI server unauthorized. Grant permissions to the exact helper path above.

If a permission toggle looks enabled but macOS still rejects the helper:

1. Remove the old helper entry from the privacy list.
2. Add the exact installed path again. Press `Command-Shift-G` in the file picker to enter it.
3. Enable the new entry.
4. Restart the supervisor or log out and back in.

The installer never modifies the macOS privacy database.

Local builds use a stable ad-hoc designated identifier at a root-protected path. A first migration from a differently signed build—or some macOS updates—may still require the helper to be removed and re-added. For distributed builds, set `CODESIGN_IDENTITY` to a Developer ID Application identity.

## Deskflow configuration

With no override, the supervisor runs:

```bash
/Applications/Deskflow.app/Contents/MacOS/deskflow-core server
```

Deskflow loads each user's default settings and server layout:

```text
~/Library/Deskflow/Deskflow.conf
~/Library/Deskflow/deskflow-server.conf
```

The installer does not copy or alter user configuration, screen layouts, certificates, or TLS keys. Screen placement can intentionally differ between accounts, so confirm the configured exit edge in each layout.

Optional supervisor arguments:

```text
--core PATH
--settings PATH
--activation-delay SECONDS
--stop-timeout SECONDS
```

Run `deskflow-session-supervisor --help` for the complete interface.

## Usage

### Status

Check every participating account:

```bash
./scripts/status.sh alice alice-work
```

Expected state:

```text
USER                   SUPERVISOR   SERVER       EXPECTED
alice                  running      running      running
alice-work             running      stopped      stopped
```

Only the active console user should own Deskflow's listening port.

### Restart

Restart the active account, or name one explicitly:

```bash
./scripts/restart.sh
./scripts/restart.sh alice
```

### Logs

Logs are stored per user:

```text
~/Library/Logs/Deskflow/active-session.out.log
~/Library/Logs/Deskflow/active-session.err.log
```

## Uninstall

Remove selected accounts:

```bash
./scripts/uninstall.sh alice alice-work
```

Discover and remove all LaunchAgents installed under local user accounts:

```bash
./scripts/uninstall.sh --all
```

This does not remove Deskflow, user configuration, certificates, logs, or macOS privacy decisions.

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
- Ad-hoc local signatures do not provide permission continuity across changed builds. Distributed releases should use a stable Developer ID signature and notarization.

## Tested environment

| macOS | Arch | Deskflow | Status |
| --- | --- | --- | --- |
| macOS 15.7.8 | x86_64 | 1.26.0 | ✅ |

The supervisor builds natively on the Mac running the installer.

## Development

Build and run smoke checks without installing:

```bash
make build
make check
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [manual Fast User Switching test](tests/manual-fast-user-switching.md).

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

This project is independent and is not affiliated with or endorsed by [Deskflow](https://github.com/deskflow/deskflow). Deskflow is not bundled, linked, or redistributed here.
