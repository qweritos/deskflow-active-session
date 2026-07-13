#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly APP_NAME="Deskflow ASM.app"
readonly MANAGER_NAME="Deskflow Active Session Manager"

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
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

staging="$temporary/Deskflow ASM"
mkdir -p "$staging"
ditto "$app_path" "$staging/$APP_NAME"
ln -s /Applications "$staging/Applications"

temporary_dmg="$temporary/Deskflow-ASM.dmg"
hdiutil create \
  -quiet \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -volname "Deskflow ASM" \
  -srcfolder "$staging" \
  "$temporary_dmg"
mv "$temporary_dmg" "$output_path"

print "Created: $output_path"
