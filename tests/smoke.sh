#!/bin/zsh
emulate -LR zsh
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

readonly ROOT_DIR=${0:A:h:h}
readonly BINARY="$ROOT_DIR/.build/release/deskflow-session-supervisor"
readonly MANAGER_BINARY="$ROOT_DIR/.build/release/deskflow-session-manager"

for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh; do
  zsh -n "$script"
done

(cd "$ROOT_DIR" && swift build -c release >/dev/null)
"$BINARY" --help >/dev/null
[[ $("$BINARY" --version) == "0.2.0" ]]
[[ $("$MANAGER_BINARY" --version) == "0.2.0" ]]
"$BINARY" --core /usr/bin/true --check >/dev/null
DESKFLOW_CORE=/usr/bin/true \
  "$ROOT_DIR/scripts/install.sh" --dry-run "$(id -un)" >/dev/null
DESKFLOW_CORE=/usr/bin/true \
  "$ROOT_DIR/scripts/install.sh" --dry-run --prebuilt "$BINARY" \
  "$(id -un)" >/dev/null
(cd "$ROOT_DIR" && swift test >/dev/null)
plutil -lint "$ROOT_DIR"/packaging/*.plist >/dev/null

CODESIGN_IDENTITY=- ARCHS=$(uname -m) \
  "$ROOT_DIR/scripts/build-manager-app.sh" >/dev/null
readonly MANAGER_APP="$ROOT_DIR/.build/Deskflow Active Session Manager.app"
readonly MANAGER_CONTENTS="$MANAGER_APP/Contents"
[[ -x "$MANAGER_CONTENTS/MacOS/Deskflow Active Session Manager" ]]
[[ -x "$MANAGER_CONTENTS/MacOS/deskflow-manager-helper" ]]
[[ ! -e "$MANAGER_CONTENTS/Library/HelperTools/deskflow-manager-helper" ]]
[[ -x "$MANAGER_CONTENTS/Resources/deskflow-session-supervisor" ]]
[[ -x "$MANAGER_CONTENTS/Resources/deskflow-manager-installer-tool" ]]
[[ $(plutil -extract BundleProgram raw \
  "$MANAGER_CONTENTS/Library/LaunchDaemons/io.github.qweritos.deskflow-active-session.manager-helper.plist") \
  == "Contents/MacOS/deskflow-manager-helper" ]]
codesign --verify --deep --strict "$MANAGER_APP"

if "$BINARY" --activation-delay invalid >/dev/null 2>&1; then
  print -u2 "invalid duration unexpectedly succeeded"
  exit 1
fi

lock_log=$(mktemp /tmp/deskflow-active-session-lock.XXXXXX)
"$BINARY" --core /usr/bin/false --stop-timeout 0 >"$lock_log" 2>&1 &
supervisor_pid=$!
cleanup_lock_test() {
  kill -TERM "$supervisor_pid" 2>/dev/null || true
  wait "$supervisor_pid" 2>/dev/null || true
  rm -f "$lock_log"
}
trap cleanup_lock_test EXIT INT TERM
sleep 0.2
if "$BINARY" --core /usr/bin/false --stop-timeout 0 >/dev/null 2>&1; then
  print -u2 "duplicate supervisor unexpectedly succeeded"
  exit 1
fi
cleanup_lock_test
trap - EXIT INT TERM

grep -q '^MIT License$' "$ROOT_DIR/LICENSE"
print "Smoke checks passed."
