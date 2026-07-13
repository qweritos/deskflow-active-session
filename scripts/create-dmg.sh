#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly APP_NAME="Deskflow ASM.app"
readonly MANAGER_NAME="Deskflow Active Session Manager"
readonly VOLUME_NAME="Deskflow ASM"
readonly BACKGROUND_NAME="dmg-background.png"
readonly BACKGROUND_SOURCE="$ROOT_DIR/packaging/$BACKGROUND_NAME"
readonly VOLUME_ICON_SOURCE="$ROOT_DIR/packaging/DeskflowASM.icns"

usage() {
  print -u2 "Usage: ${0:t} [--app PATH] [--output PATH] [--arch arm64|x86_64]"
  exit 64
}

app_path="$ROOT_DIR/.build/$APP_NAME"
output_path=""
expected_arch=$(uname -m)

while (( $# )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path=$2
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || usage
      output_path=$2
      shift 2
      ;;
    --arch)
      (( $# >= 2 )) || usage
      expected_arch=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$expected_arch" == "arm64" || "$expected_arch" == "x86_64" ]] || usage
[[ -d "$app_path" && ! -L "$app_path" ]] || {
  print -u2 "Manager application not found: $app_path"
  exit 66
}
[[ -f "$BACKGROUND_SOURCE" && ! -L "$BACKGROUND_SOURCE" ]] || {
  print -u2 "DMG background not found: $BACKGROUND_SOURCE"
  exit 66
}
[[ -f "$VOLUME_ICON_SOURCE" && ! -L "$VOLUME_ICON_SOURCE" ]] || {
  print -u2 "DMG volume icon not found: $VOLUME_ICON_SOURCE"
  exit 66
}

readonly manager="$app_path/Contents/MacOS/$MANAGER_NAME"
[[ -x "$manager" ]] || {
  print -u2 "Manager executable not found: $manager"
  exit 66
}

version=$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app_path/Contents/Info.plist"
)
[[ -n "$version" && $version != *[^0-9.]* ]] || {
  print -u2 "The manager bundle has an invalid version."
  exit 65
}
if [[ "$expected_arch" == "$(uname -m)" ]]; then
  [[ $($manager --version) == "$version" ]] || {
    print -u2 "The manager executable and bundle versions do not match."
    exit 65
  }
fi

architectures=(${(z)$(lipo -archs "$manager")})
[[ ${#architectures} -eq 1 && "$architectures[1]" == "$expected_arch" ]] || {
  print -u2 "Expected a single $expected_arch manager binary; found: ${architectures[*]}"
  exit 65
}
codesign --verify --deep --strict "$app_path"

if [[ -z "$output_path" ]]; then
  output_path="$ROOT_DIR/.build/release-artifacts/Deskflow-ASM-$version-macos-$expected_arch.dmg"
fi
[[ ${output_path:e} == "dmg" ]] || {
  print -u2 "Output path must end in .dmg"
  exit 64
}

mkdir -p "${output_path:h}"
temporary=$(mktemp -d /tmp/deskflow-asm-dmg.XXXXXX)
typeset mounted_device=""
cleanup() {
  if [[ -n "$mounted_device" ]]; then
    hdiutil detach -quiet "$mounted_device" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

staging="$temporary/Deskflow ASM"
mkdir -p "$staging/.background"
ditto "$app_path" "$staging/$APP_NAME"
ln -s /Applications "$staging/Applications"
install -m 644 "$BACKGROUND_SOURCE" \
  "$staging/.background/$BACKGROUND_NAME"
install -m 644 "$VOLUME_ICON_SOURCE" "$staging/.VolumeIcon.icns"

read_write_dmg="$temporary/Deskflow-ASM-read-write.dmg"
hdiutil create \
  -quiet \
  -ov \
  -format UDRW \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -srcfolder "$staging" \
  "$read_write_dmg"

attach_output=$(hdiutil attach -readwrite -noverify -noautoopen "$read_write_dmg")
mounted_device=$(
  print -r -- "$attach_output" \
    | sed -n 's|^\(/dev/[^[:space:]]*\).*$|\1|p' \
    | head -n 1
)
mount_point=$(
  print -r -- "$attach_output" \
    | sed -n 's|^.*\t\(/Volumes/.*\)$|\1|p' \
    | tail -n 1
)
[[ -n "$mounted_device" && -n "$mount_point" ]] || {
  print -u2 "Could not mount the writable disk image."
  exit 70
}
mounted_volume_name=${mount_point:t}

/usr/bin/SetFile -a V "$mount_point/.background"
/usr/bin/SetFile -a V "$mount_point/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$mount_point"

/usr/bin/osascript <<APPLESCRIPT
set backgroundImage to POSIX file "$mount_point/.background/$BACKGROUND_NAME" as alias
tell application "Finder"
  tell disk "$mounted_volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set sidebar width of container window to 0
    set bounds of container window to {180, 160, 840, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set text size of theViewOptions to 13
    set label position of theViewOptions to bottom
    set background picture of theViewOptions to backgroundImage
    set position of item "$APP_NAME" to {170, 215}
    set position of item "Applications" to {490, 215}
    update without registering applications
    delay 2
    close container window
  end tell
end tell
APPLESCRIPT

/usr/bin/ditto "$VOLUME_ICON_SOURCE" "$mount_point/.VolumeIcon.icns"
/usr/bin/SetFile -a V "$mount_point/.VolumeIcon.icns"
/usr/bin/SetFile -a C "$mount_point"
sync
hdiutil detach -quiet "$mounted_device"
mounted_device=""

temporary_dmg="$temporary/Deskflow-ASM.dmg"
hdiutil convert \
  -quiet \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$temporary_dmg" \
  "$read_write_dmg"
mv "$temporary_dmg" "$output_path"

print "Created: $output_path"
