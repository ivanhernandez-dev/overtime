#!/bin/bash

new_sandbox
ln -s "$REPO/scripts/tests/shim.sh" "$T/bin/curl"

INSTALL="$REPO/scripts/ci/install-xcodegen.sh"
LINT="$REPO/scripts/ci/actionlint.sh"
TOOL_LOG="$T/tool.log"
RAN_MARKER="$T/fake-tool-ran"

mkdir -p "$T/fake/xcodegen/bin" "$T/fake/lint"
printf '#!/bin/bash\n: > "%s"\necho "Version: 2.46.0"\n' "$RAN_MARKER" > "$T/fake/xcodegen/bin/xcodegen"
printf '#!/bin/bash\n: > "%s"\necho "1.7.12"\n' "$RAN_MARKER" > "$T/fake/lint/actionlint"
chmod 755 "$T/fake/xcodegen/bin/xcodegen" "$T/fake/lint/actionlint"
(cd "$T/fake" && zip -qr "$T/fake-xcodegen.zip" xcodegen)
tar -czf "$T/fake-actionlint.tar.gz" -C "$T/fake/lint" actionlint

pin_value() {
  awk -F '=' -v key="$1" '$1 == key { print $2; exit }' "$REPO/scripts/release/pins.env"
}

is_digest() {
  local value
  value="$(pin_value "$1")"
  printf '%s\n' "$value" | grep -Eqx '[0-9a-f]{64}' || { printf '%s=%s\n' "$1" "$value"; return 1; }
}

xcodegen_refuses_a_wrong_digest() {
  local status
  : > "$SHIM_LOG"
  /bin/bash "$INSTALL" "$T/xcodegen-dest" --zip "$T/fake-xcodegen.zip" > "$TOOL_LOG" 2>&1
  status=$?
  [ "$status" -eq 1 ] && grep -q 'digest' "$TOOL_LOG" && [ -z "$(ls -A "$T/xcodegen-dest")" ] \
    && [ ! -e "$RAN_MARKER" ] || { printf 'exit %s\n' "$status"; cat "$TOOL_LOG"; ls -A "$T/xcodegen-dest"; return 1; }
}

actionlint_refuses_a_wrong_digest() {
  local status
  : > "$SHIM_LOG"
  RUNNER_TEMP="$T/runner-temp" /bin/bash "$LINT" --tarball "$T/fake-actionlint.tar.gz" > "$TOOL_LOG" 2>&1
  status=$?
  [ "$status" -eq 1 ] && grep -q 'digest' "$TOOL_LOG" && [ ! -e "$RAN_MARKER" ] \
    && [ -z "$(ls -A "$T/runner-temp")" ] || { printf 'exit %s\n' "$status"; cat "$TOOL_LOG"; return 1; }
}

usage_exit() {
  /bin/bash "$@" > "$TOOL_LOG" 2>&1
  [ "$?" -eq 64 ] || { cat "$TOOL_LOG"; return 1; }
}

xcodegen_refuses_a_non_empty_destination() {
  local status
  mkdir -p "$T/busy"
  : > "$T/busy/leftover"
  /bin/bash "$INSTALL" "$T/busy" --zip "$T/fake-xcodegen.zip" > "$TOOL_LOG" 2>&1
  status=$?
  [ "$status" -eq 1 ] && grep -q 'new or empty' "$TOOL_LOG" || { cat "$TOOL_LOG"; return 1; }
}

parses_under_bin_bash() {
  head -1 "$1" | grep -qx '#!/bin/bash' && /bin/bash -n "$1"
}

mkdir "$T/runner-temp"
check "install-xcodegen refuses a zip whose digest is not the pin and extracts nothing" xcodegen_refuses_a_wrong_digest
check "install-xcodegen with --zip makes no curl call" no_shim_calls curl
check "actionlint.sh refuses a tarball whose digest is not the pin and runs nothing" actionlint_refuses_a_wrong_digest
check "actionlint.sh with --tarball makes no curl call" no_shim_calls curl
check "install-xcodegen refuses a non-empty destination" xcodegen_refuses_a_non_empty_destination
check "install-xcodegen without a destination exits 64" usage_exit "$INSTALL"
check "actionlint.sh with an unknown flag exits 64" usage_exit "$LINT" --fix
check "pins.env XCODEGEN_ZIP_SHA256 is 64 lowercase hex" is_digest XCODEGEN_ZIP_SHA256
check "pins.env ACTIONLINT_DARWIN_ARM64_SHA256 is 64 lowercase hex" is_digest ACTIONLINT_DARWIN_ARM64_SHA256
check "install-xcodegen.sh starts with #!/bin/bash and parses under /bin/bash" parses_under_bin_bash "$INSTALL"
check "actionlint.sh starts with #!/bin/bash and parses under /bin/bash" parses_under_bin_bash "$LINT"
