#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly CONFIGURATION=${CONFIGURATION:-release}
readonly APP_NAME="Deskflow ASM.app"
readonly APP_PATH="$ROOT_DIR/.build/$APP_NAME"
readonly CONTENTS="$APP_PATH/Contents"
readonly MANAGER_NAME="Deskflow Active Session Manager"
readonly HELPER_NAME="deskflow-manager-helper"
readonly SUPERVISOR_NAME="deskflow-session-supervisor"
readonly INSTALLER_TOOL_NAME="deskflow-manager-installer-tool"
readonly MANAGER_ID="io.github.qweritos.deskflow-active-session.manager"
readonly HELPER_ID="io.github.qweritos.deskflow-active-session.manager-helper"
readonly SUPERVISOR_ID="io.github.qweritos.deskflow-active-session.supervisor"
readonly INSTALLER_TOOL_ID="io.github.qweritos.deskflow-active-session.installer-tool"
readonly HELPER_PLIST="$HELPER_ID.plist"

typeset -a ARCHITECTURES
ARCHITECTURES=("${(@s: :)${ARCHS:-$(uname -m)}}")
(( ${#ARCHITECTURES} > 0 )) || {
  print -u2 "ARCHS must contain at least one architecture"
  exit 64
}

identity=${CODESIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n '/CSSMERR_/d; s/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) .*/\1/p' \
    | head -n 1)
fi
identity=${identity:--}

temporary=$(mktemp -d /tmp/deskflow-manager-build.XXXXXX)
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

build_product() {
  local architecture=$1
  local product=$2
  local scratch="$ROOT_DIR/.build/manager-$architecture"
  local triple="$architecture-apple-macosx13.0"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$scratch" \
    --configuration "$CONFIGURATION" \
    --triple "$triple" \
    --product "$product"
  swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$scratch" \
    --configuration "$CONFIGURATION" \
    --triple "$triple" \
    --show-bin-path
}

assemble_product() {
  local product=$1
  local output=$2
  typeset -a inputs
  local architecture bin_dir

  for architecture in $ARCHITECTURES; do
    bin_dir=$(build_product "$architecture" "$product" | tail -n 1)
    inputs+=("$bin_dir/$product")
  done

  if (( ${#inputs} == 1 )); then
    install -m 755 "$inputs[1]" "$output"
  else
    lipo -create $inputs -output "$output"
    chmod 755 "$output"
  fi
}

sign_code() {
  local code_path=$1
  local identifier=$2
  local stable_adhoc=${3:-0}
  if [[ "$identity" == "-" && "$stable_adhoc" == 1 ]]; then
    codesign --force --sign - --identifier "$identifier" \
      --requirements "=designated => identifier \"$identifier\"" "$code_path"
  elif [[ "$identity" == "-" ]]; then
    codesign --force --sign - --identifier "$identifier" "$code_path"
  else
    codesign --force --sign "$identity" --identifier "$identifier" \
      --options runtime "$code_path"
  fi
}

rm -rf "$APP_PATH"
install -d \
  "$CONTENTS/MacOS" \
  "$CONTENTS/Resources" \
  "$CONTENTS/Library/LaunchDaemons"
install -m 644 "$ROOT_DIR/packaging/DeskflowManager-Info.plist" \
  "$CONTENTS/Info.plist"
install -m 644 "$ROOT_DIR/packaging/$HELPER_PLIST" \
  "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST"
install -m 644 "$ROOT_DIR/LICENSE" "$CONTENTS/Resources/LICENSE"

assemble_product deskflow-session-manager "$CONTENTS/MacOS/$MANAGER_NAME"
assemble_product "$HELPER_NAME" "$CONTENTS/MacOS/$HELPER_NAME"
assemble_product "$SUPERVISOR_NAME" "$CONTENTS/Resources/$SUPERVISOR_NAME"
assemble_product "$INSTALLER_TOOL_NAME" "$CONTENTS/Resources/$INSTALLER_TOOL_NAME"

sign_code "$CONTENTS/Resources/$SUPERVISOR_NAME" "$SUPERVISOR_ID" 1
sign_code "$CONTENTS/Resources/$INSTALLER_TOOL_NAME" "$INSTALLER_TOOL_ID"
sign_code "$CONTENTS/MacOS/$HELPER_NAME" "$HELPER_ID"
sign_code "$APP_PATH" "$MANAGER_ID"

plutil -lint "$CONTENTS/Info.plist" \
  "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST" >/dev/null
codesign --verify --deep --strict "$APP_PATH"

print "Built: $APP_PATH"
print "Signed with: $identity"
if [[ "$identity" == "-" ]]; then
  print "Warning: SMAppService requires a properly signed app; use CODESIGN_IDENTITY."
elif ! gatekeeper_diagnostic=$(spctl -a -vv -t exec "$APP_PATH" 2>&1); then
  print "Warning: Gatekeeper did not accept this local signature. Check the"
  print "signing certificate before registering the management helper."
  print "${${(f)gatekeeper_diagnostic}[1]}"
fi
