#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
if [[ -z ${DESKFLOW_MANAGER_INSTALL_LOCKED:-} ]]; then
  /bin/mkdir -p "$ROOT_DIR/.build"
  export DESKFLOW_MANAGER_INSTALL_LOCKED=1
  exec /usr/bin/lockf -k -t 0 \
    "$ROOT_DIR/.build/manager-install.lock" "$0" "$@"
fi
readonly APP_NAME="Deskflow Active Session Manager.app"
readonly MANAGER_NAME="Deskflow Active Session Manager"
readonly BUILD_APP="$ROOT_DIR/.build/$APP_NAME"
readonly INSTALL_APP="/Applications/$APP_NAME"
readonly HELPER_LABEL="io.github.qweritos.deskflow-active-session.manager-helper"
readonly HELPER_TARGET="system/$HELPER_LABEL"
readonly HELPER_PLIST="$HELPER_LABEL.plist"
readonly INSTALLER_TOOL="deskflow-manager-installer-tool"
readonly MANAGER_ID="io.github.qweritos.deskflow-active-session.manager"
readonly HELPER_ID="io.github.qweritos.deskflow-active-session.manager-helper"
readonly SUPERVISOR_ID="io.github.qweritos.deskflow-active-session.supervisor"
readonly INSTALLER_TOOL_ID="io.github.qweritos.deskflow-active-session.installer-tool"
readonly STATE_PARENT="/Library/Application Support/io.github.qweritos.deskflow-active-session"

typeset stage_root=""
typeset staged_app=""
typeset backup_app=""
typeset transaction_tool=""
typeset -i promotion_started=0
typeset -i promotion_is_exchange=0
typeset -i promotion_outcome_unknown=0
typeset -i promotion_in_progress=0
typeset -i helper_was_registered=0
typeset -i helper_unregistered=0
typeset -i install_committed=0
typeset -i rollback_incomplete=0
typeset -i barrier_held=0
typeset -i barrier_pid=0
typeset -i journal_written=0
typeset previous_helper_status="not-registered"
typeset pending_renewal="none"

root_directory_exists() {
  sudo /bin/test -d "$1" && sudo /bin/test ! -L "$1"
}

verify_app() {
  local app_path=$1
  local require_installer=${2:-1}
  local contents="$app_path/Contents"

  sudo /bin/test -d "$app_path"
  sudo /bin/test ! -L "$app_path"
  sudo /bin/test -x "$contents/MacOS/$MANAGER_NAME"
  sudo /bin/test -x "$contents/MacOS/deskflow-manager-helper"
  sudo /bin/test -x "$contents/Resources/deskflow-session-supervisor"
  if (( require_installer )); then
    sudo /bin/test -x "$contents/Resources/$INSTALLER_TOOL"
  fi
  sudo /usr/bin/plutil -lint \
    "$contents/Info.plist" \
    "$contents/Library/LaunchDaemons/$HELPER_PLIST" >/dev/null
  sudo /usr/bin/codesign --verify --deep --strict "$app_path"

  local bundle_id manager_id helper_id supervisor_id installer_id bundle_program
  bundle_id=$(sudo /usr/bin/plutil -extract CFBundleIdentifier raw \
    "$contents/Info.plist")
  bundle_program=$(sudo /usr/bin/plutil -extract BundleProgram raw \
    "$contents/Library/LaunchDaemons/$HELPER_PLIST")
  manager_id=$(sudo /usr/bin/codesign -d --verbose=4 "$app_path" 2>&1 \
    | /usr/bin/sed -n 's/^Identifier=//p')
  helper_id=$(sudo /usr/bin/codesign -d --verbose=4 \
    "$contents/MacOS/deskflow-manager-helper" 2>&1 \
    | /usr/bin/sed -n 's/^Identifier=//p')
  supervisor_id=$(sudo /usr/bin/codesign -d --verbose=4 \
    "$contents/Resources/deskflow-session-supervisor" 2>&1 \
    | /usr/bin/sed -n 's/^Identifier=//p')
  [[ "$bundle_id" == "$MANAGER_ID" \
    && "$manager_id" == "$MANAGER_ID" \
    && "$helper_id" == "$HELPER_ID" \
    && "$supervisor_id" == "$SUPERVISOR_ID" \
    && "$bundle_program" == "Contents/MacOS/deskflow-manager-helper" ]]
  if (( require_installer )); then
    installer_id=$(sudo /usr/bin/codesign -d --verbose=4 \
      "$contents/Resources/$INSTALLER_TOOL" 2>&1 \
      | /usr/bin/sed -n 's/^Identifier=//p')
    [[ "$installer_id" == "$INSTALLER_TOOL_ID" ]]
  fi

  local owner
  owner=$(sudo /usr/bin/stat -f '%Su:%Sg' "$app_path")
  [[ "$owner" == "root:wheel" ]] || {
    print -u2 "Staged manager app has unexpected ownership: $owner"
    return 1
  }
}

manager_command() {
  local app_path=$1
  shift
  "$app_path/Contents/MacOS/$MANAGER_NAME" "$@"
}

acquire_operation_barrier() {
  local tool_path=$1
  local response=""
  coproc sudo "$tool_path" hold-lock
  barrier_pid=$!
  if ! read -r -p response || [[ "$response" != "locked" ]]; then
    wait $barrier_pid 2>/dev/null || true
    barrier_pid=0
    print -u2 "The management helper is busy; wait for the current operation and retry."
    return 1
  fi
  barrier_held=1
}

release_operation_barrier() {
  (( barrier_held )) || return 0
  print -p -- release 2>/dev/null || true
  wait $barrier_pid 2>/dev/null || true
  barrier_held=0
  barrier_pid=0
}

require_helper_health() {
  local app_path=$1
  local expected_status=$2
  local service_status
  service_status=$(manager_command "$app_path" --helper-status 2>/dev/null || true)
  if [[ "$service_status" != "enabled" && "$service_status" != "requires-approval" ]]; then
    service_status=$(manager_command "$app_path" --register-helper) || return 1
  fi
  if [[ "$expected_status" == "enabled" && "$service_status" != "enabled" ]]; then
    print -u2 "The management helper has status $service_status; enabled was expected."
    return 1
  fi
  if [[ "$service_status" == "enabled" ]]; then
    local expected_version helper_version
    expected_version=$(manager_command "$app_path" --version)
    helper_version=$(manager_command "$app_path" --helper-version) || return 1
    [[ "$helper_version" == "$expected_version" ]] || {
      print -u2 "The management helper returned version $helper_version; expected $expected_version."
      return 1
    }
  fi
  return 0
}

rollback_install() {
  local rollback_failed=0

  (( promotion_started || helper_unregistered || journal_written )) || return 0
  print -u2 "Manager app installation failed; restoring the previous installation."

  if (( promotion_outcome_unknown )); then
    rollback_incomplete=1
    print -u2 "The atomic exchange outcome is unknown; preserving both app copies and recovery state."
    return 1
  fi

  if (( helper_unregistered )) && root_directory_exists "$INSTALL_APP"; then
    manager_command "$INSTALL_APP" --unregister-helper >/dev/null 2>&1 || true
  fi

  if (( promotion_started && promotion_is_exchange )); then
    if root_directory_exists "$INSTALL_APP" && root_directory_exists "$backup_app"; then
      if ! sudo "$transaction_tool" \
        swap "$backup_app" "$INSTALL_APP"
      then
        print -u2 "Could not atomically restore the previous manager app."
        rollback_failed=1
      fi
    else
      print -u2 "The manager app exchange cannot be rolled back safely."
      rollback_failed=1
    fi
  elif (( promotion_started )) && root_directory_exists "$INSTALL_APP"; then
    if ! sudo /bin/mv "$INSTALL_APP" "$staged_app"; then
      print -u2 "Could not remove the failed first installation."
      rollback_failed=1
    fi
  fi

  if (( journal_written && !rollback_failed )) && root_directory_exists "$INSTALL_APP"; then
    local restored_status
    restored_status=$(manager_command "$INSTALL_APP" --helper-status 2>/dev/null || true)
    if [[ "$restored_status" == "enabled" \
      || "$restored_status" == "requires-approval" ]]
    then
      if ! manager_command "$INSTALL_APP" --unregister-helper >/dev/null; then
        print -u2 "Warning: the restored management helper could not be reset."
        rollback_failed=1
      fi
    fi
    if (( !rollback_failed )) \
      && ! require_helper_health "$INSTALL_APP" "$previous_helper_status"
    then
      print -u2 "Warning: the restored management helper could not be re-registered."
      rollback_failed=1
    fi
  fi

  if (( journal_written && !rollback_failed )); then
    if sudo "$transaction_tool" journal-clear; then
      journal_written=0
    else
      print -u2 "Warning: the helper-renewal recovery journal could not be cleared."
      rollback_failed=1
    fi
  fi

  if (( rollback_failed )); then
    rollback_incomplete=1
    print -u2 "Rollback data was preserved at: $stage_root"
    return 1
  fi
  return 0
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM

  if (( exit_status != 0 && !install_committed )); then
    rollback_install || true
  fi
  release_operation_barrier

  if [[ -n "$stage_root" ]] && root_directory_exists "$stage_root"; then
    if (( rollback_incomplete )); then
      print -u2 "Preserving installation backup at: $stage_root"
    elif ! sudo /bin/rm -rf "$stage_root" >/dev/null 2>&1; then
      print -u2 "Warning: could not remove staging directory: $stage_root"
    fi
  fi
  exit $exit_status
}

handle_signal() {
  local exit_code=$1
  if (( promotion_in_progress )); then
    promotion_outcome_unknown=1
  fi
  exit $exit_code
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

(( EUID != 0 )) || {
  print -u2 "Run this script as your login user; it requests sudo when needed."
  exit 64
}

if /usr/bin/pgrep -f \
  '/Applications/Deskflow Active Session Manager[.]app/Contents/MacOS/Deskflow Active Session Manager' \
  >/dev/null 2>&1
then
  print -u2 "Quit Deskflow Active Session Manager in every user session before upgrading it."
  exit 75
fi

"$ROOT_DIR/scripts/build-manager-app.sh"
/usr/bin/codesign --verify --deep --strict "$BUILD_APP"

sudo -n true 2>/dev/null || sudo -v
if sudo /bin/test -L "$STATE_PARENT"; then
  print -u2 "Refusing symbolic-link manager state directory: $STATE_PARENT"
  exit 73
fi
sudo /usr/bin/install -d -o root -g wheel -m 755 "$STATE_PARENT"
sudo /bin/chmod -N "$STATE_PARENT"
sudo /bin/chmod 755 "$STATE_PARENT"
sudo /usr/sbin/chown root:wheel "$STATE_PARENT"
stage_root=$(sudo /usr/bin/mktemp -d \
  "$STATE_PARENT/staging.XXXXXX")
sudo /bin/chmod -N "$stage_root"
sudo /bin/chmod 700 "$stage_root"
sudo /usr/sbin/chown root:wheel "$stage_root"
staged_app="$stage_root/$APP_NAME"
backup_app="$staged_app"
transaction_tool="$stage_root/$INSTALLER_TOOL"

if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
  [[ -d "$INSTALL_APP" && ! -L "$INSTALL_APP" ]] || {
    print -u2 "Refusing to replace a non-directory or symbolic link: $INSTALL_APP"
    exit 73
  }
fi

sudo /usr/bin/ditto "$BUILD_APP" "$staged_app"
sudo /bin/chmod -RN "$staged_app"
sudo /bin/chmod -R go-w "$staged_app"
sudo /usr/sbin/chown -R root:wheel "$staged_app"

# Verify the exact root-owned payload before any change to the canonical path.
verify_app "$staged_app"
sudo /usr/bin/install -o root -g wheel -m 755 \
  "$staged_app/Contents/Resources/$INSTALLER_TOOL" "$transaction_tool"
sudo /bin/chmod -N "$transaction_tool"
sudo /usr/bin/codesign --verify --strict "$transaction_tool"
transaction_tool_id=$(sudo /usr/bin/codesign -d --verbose=4 \
  "$transaction_tool" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
[[ "$transaction_tool_id" == "$INSTALLER_TOOL_ID" ]]
[[ $(sudo /usr/bin/stat -f '%Su:%Sg:%OLp' "$stage_root") == "root:wheel:700" ]]
[[ $(sudo /usr/bin/stat -f '%Su:%Sg:%OLp' "$transaction_tool") \
  == "root:wheel:755" ]]

acquire_operation_barrier "$transaction_tool"
pending_renewal=$(sudo "$transaction_tool" journal-read)

if root_directory_exists "$INSTALL_APP"; then
  sudo "$transaction_tool" verify-installed
  verify_app "$INSTALL_APP" 0
  existing_helper_status=$(manager_command "$INSTALL_APP" --helper-status 2>/dev/null || true)
  if [[ "$pending_renewal" != "none" ]]; then
    helper_was_registered=1
    previous_helper_status=$pending_renewal
    print "Recovering an interrupted management-helper renewal."
  elif [[ "$existing_helper_status" == "enabled" \
    || "$existing_helper_status" == "requires-approval" ]]
  then
    helper_was_registered=1
    previous_helper_status=$existing_helper_status
    print "Existing management helper registration detected; it will be renewed."
  elif sudo /bin/launchctl print "$HELPER_TARGET" >/dev/null 2>&1; then
    helper_was_registered=1
    previous_helper_status="enabled"
    print "Existing management helper registration detected; it will be renewed."
  fi
elif [[ "$pending_renewal" != "none" ]]; then
  print -u2 "A helper-renewal journal exists, but the manager app is missing."
  exit 70
fi

if [[ "$pending_renewal" != "none" ]]; then
  recovery_status=$(manager_command "$INSTALL_APP" --helper-status 2>/dev/null || true)
  if [[ "$recovery_status" == "enabled" \
    || "$recovery_status" == "requires-approval" ]]
  then
    manager_command "$INSTALL_APP" --unregister-helper >/dev/null
  fi
  require_helper_health "$INSTALL_APP" "$pending_renewal" || {
    print -u2 "The interrupted management-helper renewal could not be recovered."
    exit 70
  }
  sudo "$transaction_tool" journal-clear
  pending_renewal="none"
fi

if (( helper_was_registered )); then
  sudo "$transaction_tool" journal-write "$previous_helper_status"
  journal_written=1
fi

if [[ -d "$INSTALL_APP" ]]; then
  promotion_is_exchange=1
  promotion_started=1
  swap_result=0
  promotion_in_progress=1
  sudo "$transaction_tool" swap "$staged_app" "$INSTALL_APP" || swap_result=$?
  promotion_in_progress=0
  if (( swap_result != 0 )); then
    if (( swap_result == 74 )); then
      # The exchange completed; only its post-commit durability sync failed.
      :
    elif (( swap_result >= 128 )); then
      promotion_outcome_unknown=1
    else
      promotion_started=0
    fi
    exit 70
  fi
else
  promotion_started=1
  promotion_in_progress=1
  if ! sudo /bin/mv "$staged_app" "$INSTALL_APP"; then
    promotion_in_progress=0
    promotion_started=0
    exit 70
  fi
  promotion_in_progress=0
fi
verify_app "$INSTALL_APP"
sudo "$transaction_tool" verify-installed

if (( !helper_was_registered )); then
  registered_status=$(manager_command "$INSTALL_APP" --helper-status 2>/dev/null || true)
  if [[ "$registered_status" == "enabled" \
    || "$registered_status" == "requires-approval" ]]
  then
    helper_was_registered=1
    previous_helper_status=$registered_status
    print "Existing management helper registration detected after promotion; it will be renewed."
  fi
fi

if (( helper_was_registered )); then
  if (( !journal_written )); then
    sudo "$transaction_tool" journal-write "$previous_helper_status"
    journal_written=1
  fi
  manager_command "$INSTALL_APP" --unregister-helper >/dev/null
  helper_unregistered=1

  # Service Management requires re-registration after an embedded executable
  # changes. With the same signing identity, the existing approval is retained.
  require_helper_health "$INSTALL_APP" "$previous_helper_status" || {
    print -u2 "The management helper could not be registered from the upgraded app."
    print -u2 "If the signing identity changed, install the old app and remove its helper first."
    exit 70
  }
  sudo "$transaction_tool" journal-clear
  journal_written=0
fi

install_committed=1
release_operation_barrier

if ! /usr/bin/open -n "$INSTALL_APP"; then
  print -u2 "Warning: the app was installed but could not be opened automatically."
fi

if (( helper_unregistered )); then
  print "Installed app and renewed the management helper registration: $INSTALL_APP"
else
  print "Installed and opened: $INSTALL_APP"
  print "Use Set Up Helper in the app if management service setup is required."
fi
