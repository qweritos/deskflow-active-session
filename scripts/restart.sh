#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly LABEL="com.local.deskflow.active-session"

authorize_sudo() {
  sudo -n true 2>/dev/null || sudo -v
}

user=${1:-$(stat -f '%Su' /dev/console)}
uid=$(dscl . -read "/Users/$user" UniqueID 2>/dev/null | awk '{print $2}')
home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
[[ "$uid" == <-> && -n "$home" ]] || {
  print -u2 "Unknown local user: $user"
  exit 67
}

plist="$home/Library/LaunchAgents/$LABEL.plist"
[[ -f "$plist" ]] || {
  print -u2 "Agent is not installed for $user"
  exit 66
}

authorize_sudo
if ! sudo launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
  sudo launchctl bootstrap "gui/$uid" "$plist"
fi
sudo launchctl kickstart -k "gui/$uid/$LABEL"
print "Restarted supervisor for $user"
