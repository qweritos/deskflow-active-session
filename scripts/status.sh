#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly LABEL="com.local.deskflow.active-session"

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

machine=0
if [[ ${1:-} == "--machine" ]]; then
  machine=1
  shift
fi

typeset -a USERS
if (( $# > 0 )); then
  USERS=("$@")
else
  USERS=("${(@f)$(discover_users)}")
fi

(( ${#USERS} > 0 )) || {
  print "No installed user agents found."
  exit 1
}

active=$(stat -f '%Su' /dev/console)
if (( machine )); then
  printf 'ACTIVE\t%s\n' "$active"
else
  print "Active desktop: $active"
  printf '%-22s %-12s %-12s %-10s\n' USER SUPERVISOR SERVER EXPECTED
fi

for user in $USERS; do
  uid=$(dscl . -read "/Users/$user" UniqueID 2>/dev/null | awk '{print $2}')
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  if [[ "$uid" != <-> ]]; then
    if (( machine )); then
      printf 'USER\t%s\tunknown\tunknown\tunknown\tunknown\n' "$user"
    else
      printf '%-22s %-12s %-12s %-10s\n' "$user" unknown unknown unknown
    fi
    continue
  fi

  installed=no
  if [[ -n "$home" ]] && sudo test -f "$home/Library/LaunchAgents/$LABEL.plist"; then
    installed=yes
  fi

  job=$(sudo launchctl print "gui/$uid/$LABEL" 2>/dev/null || true)
  agent_pid=$(awk '/^[[:space:]]*pid =/ {print $3; exit}' <<<"$job")
  if [[ "$agent_pid" == <-> ]]; then
    supervisor=running
  elif [[ -n "$job" ]]; then
    supervisor=loaded
  else
    supervisor=stopped
  fi

  if [[ "$agent_pid" == <-> ]] && pgrep -P "$agent_pid" -x deskflow-core >/dev/null 2>&1; then
    server=running
  else
    server=stopped
  fi

  [[ "$user" == "$active" ]] && expected=running || expected=stopped
  if (( machine )); then
    printf 'USER\t%s\t%s\t%s\t%s\t%s\n' \
      "$user" "$installed" "$supervisor" "$server" "$expected"
  else
    printf '%-22s %-12s %-12s %-10s\n' "$user" "$supervisor" "$server" "$expected"
  fi
done

owner=$(sudo lsof -nP -iTCP:24800 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $3 " (pid " $2 ")"}')
if (( machine )); then
  printf 'PORT\t%s\n' "${owner:-none}"
else
  print "TCP 24800 owner: ${owner:-none}"
fi
