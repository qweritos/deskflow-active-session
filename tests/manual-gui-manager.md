# Manual GUI manager test

Run this test on a Mac with two local GUI accounts and a valid Deskflow server configuration in each account.

Before testing:

- Sign into both accounts so both have Aqua sessions.
- Configure Deskflow server mode and the screen edge separately in each account.
- Quit the Deskflow GUI and disable its own login item in both accounts.
- Keep a configured remote Deskflow client available to verify input sharing.

## Build and setup

1. Build and install the manager with an Apple Development or Developer ID signing identity:

   ```bash
   ./scripts/install-manager-app.sh
   ```

2. Confirm the app is located at `/Applications/Deskflow Active Session Manager.app`.
3. Open the app and select **Set Up Helper**.
4. If the helper requires approval, enable it under **System Settings → General → Login Items**, then return to the app.
5. Confirm status refreshes without an administrator authorization dialog.
6. Confirm service accounts and accounts with disabled login shells cannot be selected.
7. Cancel one administrator authorization request and confirm no installation state changes.
8. Expand **Event Log** at the bottom of the window and confirm startup, helper verification, and refresh events are present.
9. Confirm **Copy** places the visible log on the clipboard and **Clear** resets it to a single clear event.

## Install and status

1. Select both participating accounts and choose **Install / Upgrade**.
2. Authenticate as an administrator.
3. Confirm each account reports a successful result.
4. Confirm the foreground account shows **Active** and the background account shows **Standby**.
5. Confirm only the active account owns TCP port 24800.

   ```bash
   sudo lsof -nP -iTCP:24800 -sTCP:LISTEN
   ```

6. Confirm the installed supervisor is:

   ```text
   /usr/local/libexec/deskflow-session-supervisor
   ```

7. Confirm each account retains its own default Deskflow screen layout and configuration.
8. Grant Accessibility and Input Monitoring to the exact installed supervisor separately in both accounts when required.

## Fast User Switching

1. Switch to the second account without logging out of the first.
2. Open the manager in the active account and refresh.
3. Wait through any transient **Starting** or **Stopping** state, refresh, then confirm the second account becomes **Active** and the first becomes **Standby**.
4. Confirm keyboard and mouse sharing reconnects through the edge configured by the second account.
5. Switch back and repeat the status checks.

## Controls

1. Select an installed account and choose **Restart**.
2. Confirm a fresh administrator authorization is requested, the operation succeeds, and status settles back to **Active** or **Standby** as appropriate.
3. Select one account and choose **Uninstall**.
4. Confirm a fresh administrator authorization is requested, only that account becomes **Not installed**, and the other account keeps working.
5. Reinstall the removed account.
6. Remove the final installed account and confirm `/usr/local/libexec/deskflow-session-supervisor` is removed.
7. Reinstall both accounts, choose **Remove Management Helper**, and confirm Fast User Switching and the existing user LaunchAgents keep working.
8. Set the helper up again and confirm status is restored.

## Permissions regression

If an install replaces a differently signed supervisor:

1. Confirm the manager points to the exact supervisor path for Accessibility and Input Monitoring.
2. Remove any stale privacy entry, add the exact path again, and enable it.
3. Switch between both accounts and confirm macOS does not repeatedly request input access.
