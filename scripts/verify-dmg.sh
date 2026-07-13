#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly APP_NAME="Deskflow ASM.app"
readonly MANAGER_NAME="Deskflow Active Session Manager"

(( $# == 2 )) || {
  print -u2 "Usage: ${0:t} DMG_PATH arm64|x86_64"
  exit 64
}

readonly dmg_path=$1
readonly expected_arch=$2
[[ "$expected_arch" == "arm64" || "$expected_arch" == "x86_64" ]] || exit 64
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || {
  print -u2 "Disk image not found: $dmg_path"
  exit 66
}

attach_output=$(hdiutil attach -readonly -nobrowse "$dmg_path")
mount_point=$(
  print -r -- "$attach_output" \
    | sed -n 's|^.*	\(/Volumes/.*\)$|\1|p' \
    | tail -n 1
)
[[ -n "$mount_point" ]] || {
  print -u2 "Could not determine the disk image mount point."
  exit 70
}
cleanup() {
  hdiutil detach -quiet "$mount_point" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

readonly app_path="$mount_point/$APP_NAME"
readonly manager="$app_path/Contents/MacOS/$MANAGER_NAME"
[[ -d "$app_path" && ! -L "$app_path" ]]
[[ -L "$mount_point/Applications" ]]
[[ $(readlink "$mount_point/Applications") == "/Applications" ]]
[[ -x "$manager" ]]
codesign --verify --deep --strict "$app_path"

architectures=(${(z)$(lipo -archs "$manager")})
[[ ${#architectures} -eq 1 && "$architectures[1]" == "$expected_arch" ]] || {
  print -u2 "Expected $expected_arch in the DMG; found: ${architectures[*]}"
  exit 65
}

print "Verified: $dmg_path ($expected_arch)"
