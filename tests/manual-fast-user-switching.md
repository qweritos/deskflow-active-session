# Manual Fast User Switching test

Use two normal macOS GUI accounts that both have Deskflow server configurations.

1. Install the project for both accounts.
2. Sign into both accounts and leave one in the background.
3. In the foreground account, verify that exactly one `deskflow-core server` process is running and the remote client connects.
4. Confirm mouse and keyboard sharing using that account's configured screen edge.
5. Use Fast User Switching to activate the second account.
6. Verify that the first account's core exits and the second account's core starts.
7. Confirm mouse and keyboard sharing using the second account's configured screen edge.
8. Switch back and repeat the checks.
9. Repeat the round trip twice to expose stale-port and notification-ordering failures.
10. Return to the first account and run `./scripts/status.sh USER1 USER2`.

Expected result: both supervisors remain running, only the active account has a Deskflow core, and TCP 24800 belongs to that active account.
