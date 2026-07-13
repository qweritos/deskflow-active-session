#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly PROJECT="$ROOT_DIR/Deskflow ASM.xcodeproj"
readonly SCHEME="Deskflow ASM"
readonly APP_NAME="Deskflow ASM.app"
readonly APP_PATH="$ROOT_DIR/.build/$APP_NAME"
readonly DERIVED_DATA="$ROOT_DIR/.build/manager-xcode-derived"

case ${CONFIGURATION:-Release} in
  [Dd]ebug) readonly XCODE_CONFIGURATION=Debug ;;
  [Rr]elease) readonly XCODE_CONFIGURATION=Release ;;
  *)
    print -u2 "CONFIGURATION must be Debug or Release"
    exit 64
    ;;
esac

typeset -a architectures
architectures=("${(@s: :)${ARCHS:-$(uname -m)}}")
(( ${#architectures} > 0 )) || {
  print -u2 "ARCHS must contain at least one architecture"
  exit 64
}
for architecture in $architectures; do
  [[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] || {
    print -u2 "Unsupported architecture: $architecture"
    exit 64
  }
done

identity=${CODESIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n '/CSSMERR_/d; s/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) .*/\1/p' \
    | head -n 1)
fi
identity=${identity:--}

typeset -a signing_settings
signing_settings=(
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=$identity"
)
if [[ "$identity" == "-" ]]; then
  signing_settings+=("DEVELOPMENT_TEAM=")
else
  development_team=${DEVELOPMENT_TEAM:-}
  if [[ -z "$development_team" ]]; then
    identity_line=$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -F "$identity" | sed -n '1p')
    identity_name=${${identity_line#*\"}%%\"*}
    if [[ -n "$identity_name" ]]; then
      certificate_subject=$(security find-certificate -c "$identity_name" -p \
        | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)
      development_team=$(print -r -- "$certificate_subject" \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p')
    fi
  fi
  [[ -n "$development_team" ]] || {
    print -u2 "Could not determine the signing team; set DEVELOPMENT_TEAM."
    exit 65
  }
  signing_settings+=("DEVELOPMENT_TEAM=$development_team")
fi

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$XCODE_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "generic/platform=macOS" \
  "ARCHS=${(j: :)architectures}" \
  "ONLY_ACTIVE_ARCH=NO" \
  $signing_settings \
  build

readonly BUILT_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/$APP_NAME"
[[ -d "$BUILT_APP" ]] || {
  print -u2 "Xcode did not produce the manager app: $BUILT_APP"
  exit 66
}

rm -rf "$APP_PATH"
/usr/bin/ditto "$BUILT_APP" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

print "Built: $APP_PATH"
print "Built natively with: xcodebuild ($XCODE_CONFIGURATION)"
print "Signed with: $identity"
if [[ "$identity" == "-" ]]; then
  print "Warning: SMAppService requires a properly signed app; use CODESIGN_IDENTITY."
elif ! gatekeeper_diagnostic=$(/usr/sbin/spctl -a -vv -t exec "$APP_PATH" 2>&1); then
  print "Warning: Gatekeeper did not accept this local signature."
  print "${${(f)gatekeeper_diagnostic}[1]}"
fi
