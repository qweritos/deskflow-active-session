#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly LABEL="com.local.deskflow.active-session"
readonly BINARY_NAME="deskflow-session-supervisor"
readonly INSTALL_BINARY="/usr/local/libexec/$BINARY_NAME"
readonly SHARE_DIR="/usr/local/share/deskflow-active-session"
readonly CORE_PATH=${DESKFLOW_CORE:-/Applications/Deskflow.app/Contents/MacOS/deskflow-core}
readonly HELPER_ID="io.github.qweritos.deskflow-active-session.supervisor"

usage() {
  print -u2 "Usage: ${0:t} [--dry-run] [--prebuilt PATH] USER [USER ...]"
  print -u2 "Example: ${0:t} alice alice-work"
}

authorize_sudo() {
  sudo -n true 2>/dev/null || sudo -v
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<<"$1"
}

render_plist() {
  local home=$1
  local output=$2
  local binary_xml core_xml stdout_xml stderr_xml
  binary_xml=$(xml_escape "$INSTALL_BINARY")
  core_xml=$(xml_escape "$CORE_PATH")
  stdout_xml=$(xml_escape "$home/Library/Logs/Deskflow/active-session.out.log")
  stderr_xml=$(xml_escape "$home/Library/Logs/Deskflow/active-session.err.log")

  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0">'
    print -r -- '<dict>'
    print -r -- '  <key>Label</key>'
    print -r -- "  <string>$LABEL</string>"
    print -r -- '  <key>ProgramArguments</key>'
    print -r -- '  <array>'
    print -r -- "    <string>$binary_xml</string>"
    print -r -- '    <string>--core</string>'
    print -r -- "    <string>$core_xml</string>"
    print -r -- '  </array>'
    print -r -- '  <key>RunAtLoad</key>'
    print -r -- '  <true/>'
    print -r -- '  <key>KeepAlive</key>'
    print -r -- '  <true/>'
    print -r -- '  <key>LimitLoadToSessionType</key>'
    print -r -- '  <string>Aqua</string>'
    print -r -- '  <key>ThrottleInterval</key>'
    print -r -- '  <integer>5</integer>'
    print -r -- '  <key>ExitTimeOut</key>'
    print -r -- '  <integer>6</integer>'
    print -r -- '  <key>StandardOutPath</key>'
    print -r -- "  <string>$stdout_xml</string>"
    print -r -- '  <key>StandardErrorPath</key>'
    print -r -- "  <string>$stderr_xml</string>"
    print -r -- '</dict>'
    print -r -- '</plist>'
  } >"$output"
}

dry_run=0
prebuilt=""
while (( $# > 0 )); do
  case $1 in
    --dry-run)
      dry_run=1
      shift
      ;;
    --prebuilt)
      (( $# >= 2 )) || {
        print -u2 "--prebuilt requires a path"
        exit 64
      }
      prebuilt=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      print -u2 "Unknown option: $1"
      usage
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

(( $# > 0 )) || {
  usage
  exit 64
}

[[ -x "$CORE_PATH" ]] || {
  print -u2 "Deskflow core is not executable: $CORE_PATH"
  exit 66
}

typeset -A USER_UID USER_HOME USER_GROUP
typeset -a USERS

for user in "$@"; do
  [[ "$user" != -* ]] || {
    print -u2 "Invalid user: $user"
    exit 64
  }

  uid=$(dscl . -read "/Users/$user" UniqueID 2>/dev/null | awk '{print $2}')
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  group=$(id -gn "$user" 2>/dev/null)
  [[ "$uid" == <-> && -n "$home" && -n "$group" ]] || {
    print -u2 "Could not resolve local user: $user"
    exit 67
  }
  (( uid >= 500 )) || {
    print -u2 "Refusing system account: $user (uid $uid)"
    exit 67
  }

  USERS+=("$user")
  USER_UID[$user]=$uid
  USER_HOME[$user]=$home
  USER_GROUP[$user]=$group
done

if [[ -n "$prebuilt" ]]; then
  BUILD_BINARY=${prebuilt:A}
  [[ -x "$BUILD_BINARY" ]] || {
    print -u2 "Prebuilt supervisor is not executable: $BUILD_BINARY"
    exit 66
  }
  codesign --verify --strict "$BUILD_BINARY"
  actual_id=$(codesign -d --verbose=4 "$BUILD_BINARY" 2>&1 \
    | sed -n 's/^Identifier=//p')
  [[ "$actual_id" == "$HELPER_ID" ]] || {
    print -u2 "Unexpected prebuilt supervisor identifier: ${actual_id:-missing}"
    exit 65
  }
  print "Using verified prebuilt supervisor."
else
  BUILD_BINARY="$ROOT_DIR/.build/release/$BINARY_NAME"
  print "Building release binary..."
  (cd "$ROOT_DIR" && swift build -c release --product "$BINARY_NAME")

  if [[ -n ${CODESIGN_IDENTITY:-} ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" \
      --identifier "$HELPER_ID" --options runtime --timestamp "$BUILD_BINARY" >/dev/null
  else
    codesign --force --sign - --identifier "$HELPER_ID" \
      --requirements "=designated => identifier \"$HELPER_ID\"" \
      "$BUILD_BINARY" >/dev/null
  fi
  codesign --verify --strict "$BUILD_BINARY"
fi
readonly BUILD_BINARY

if (( dry_run )); then
  for user in $USERS; do
    temporary=$(mktemp /tmp/deskflow-active-session.XXXXXX)
    render_plist "${USER_HOME[$user]}" "$temporary"
    plutil -lint "$temporary" >/dev/null
    rm -f "$temporary"
    print "Validated LaunchAgent for $user"
  done
  print "Dry run complete; no installed files or jobs were changed."
  exit 0
fi

authorize_sudo

for user in $USERS; do
  uid=${USER_UID[$user]}
  sudo launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
done
sleep 5

sudo install -d -o root -g wheel -m 755 /usr/local/libexec "$SHARE_DIR"
sudo install -o root -g wheel -m 755 "$BUILD_BINARY" "$INSTALL_BINARY"
sudo install -o root -g wheel -m 644 \
  "$ROOT_DIR/Sources/DeskflowSessionSupervisor/main.swift" \
  "$SHARE_DIR/DeskflowSessionSupervisor.swift"
sudo install -o root -g wheel -m 644 "$ROOT_DIR/LICENSE" "$SHARE_DIR/LICENSE"

for user in $USERS; do
  uid=${USER_UID[$user]}
  home=${USER_HOME[$user]}
  agent_dir="$home/Library/LaunchAgents"
  log_dir="$home/Library/Logs/Deskflow"
  plist="$agent_dir/$LABEL.plist"
  temporary=$(mktemp /tmp/deskflow-active-session.XXXXXX)

  render_plist "$home" "$temporary"
  plutil -lint "$temporary" >/dev/null
  chmod 644 "$temporary"
  sudo -u "$user" install -d -m 755 "$agent_dir" "$log_dir"
  sudo -u "$user" install -m 644 "$temporary" "$plist"
  rm -f "$temporary"

  if sudo launchctl print "gui/$uid" >/dev/null 2>&1; then
    sudo launchctl bootstrap "gui/$uid" "$plist"
    print "Installed and started for $user (uid $uid)"
  else
    print "Installed for $user; it will start at the next GUI login"
  fi
done

print
print "Installed: $INSTALL_BINARY"
print "If macOS denies input access, remove and re-add this exact binary in"
print "System Settings > Privacy & Security > Accessibility and Input Monitoring."
print "A rebuilt ad-hoc binary has a new code identity even if an old toggle remains enabled."
