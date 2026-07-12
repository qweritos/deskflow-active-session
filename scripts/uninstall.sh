#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly LABEL="com.local.deskflow.active-session"
readonly INSTALL_BINARY="/usr/local/libexec/deskflow-session-supervisor"
readonly SHARE_DIR="/usr/local/share/deskflow-active-session"

authorize_sudo() {
  sudo -n true 2>/dev/null || sudo -v
}

discover_users() {
  while read -r user; do
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
    if [[ -n "$home" ]] && sudo test -f "$home/Library/LaunchAgents/$LABEL.plist"; then
      print "$user"
    fi
  done < <(dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1}')
  return 0
}

authorize_sudo

typeset -a USERS
if [[ ${1:-} == "--all" ]]; then
  shift
  (( $# == 0 )) || {
    print -u2 "--all cannot be combined with user names"
    exit 64
  }
  USERS=("${(@f)$(discover_users)}")
elif (( $# > 0 )); then
  USERS=("$@")
else
  print -u2 "Usage: ${0:t} USER [USER ...]"
  print -u2 "       ${0:t} --all"
  exit 64
fi

(( ${#USERS} > 0 )) || {
  print "No installed user agents found."
  exit 0
}

for user in $USERS; do
  uid=$(dscl . -read "/Users/$user" UniqueID 2>/dev/null | awk '{print $2}')
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [[ "$uid" == <-> && -n "$home" ]] || {
    print -u2 "Skipping unknown user: $user"
    continue
  }

  plist="$home/Library/LaunchAgents/$LABEL.plist"
  if sudo test -f "$plist"; then
    installed_label=$(sudo plutil -extract Label raw -o - "$plist" 2>/dev/null || true)
    [[ "$installed_label" == "$LABEL" ]] || {
      print -u2 "Refusing unexpected plist: $plist"
      continue
    }
  fi

  sudo launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
  sudo -u "$user" rm -f "$plist"
  print "Removed user agent for $user"
done

sleep 5

remaining=0
for user in ${(f)"$(dscl . -list /Users UniqueID | awk '$2 >= 500 {print $1}')"}; do
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  if [[ -n "$home" ]] && sudo test -f "$home/Library/LaunchAgents/$LABEL.plist"; then
    remaining=1
    break
  fi
done

if (( remaining == 0 )); then
  sudo rm -f "$INSTALL_BINARY"
  sudo rm -rf "$SHARE_DIR"
  print "Removed shared supervisor files."
else
  print "Shared files retained because other user agents remain installed."
fi

print "Deskflow configuration, certificates, logs, and macOS permissions were not removed."
