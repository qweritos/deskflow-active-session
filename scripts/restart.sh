#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly LABEL="com.local.deskflow.active-session"

authorize_sudo() {
  sudo -n true 2>/dev/null || sudo -v
}

typeset -a USERS
if (( $# > 0 )); then
  USERS=("$@")
else
  USERS=("$(stat -f '%Su' /dev/console)")
fi

typeset -A USER_UID USER_PLIST
for user in $USERS; do
  uid=$(dscl . -read "/Users/$user" UniqueID 2>/dev/null | awk '{print $2}')
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [[ "$uid" == <-> && -n "$home" ]] || {
    print -u2 "Unknown local user: $user"
    exit 67
  }
  USER_UID[$user]=$uid
  USER_PLIST[$user]="$home/Library/LaunchAgents/$LABEL.plist"
done

authorize_sudo
for user in $USERS; do
  uid=${USER_UID[$user]}
  plist=${USER_PLIST[$user]}
  sudo test -f "$plist" || {
    print -u2 "Agent is not installed for $user"
    exit 66
  }
  if ! sudo launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
    sudo launchctl bootstrap "gui/$uid" "$plist"
  fi
  sudo launchctl kickstart -k "gui/$uid/$LABEL"
  print "Restarted supervisor for $user"
done
