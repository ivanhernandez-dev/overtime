#!/bin/bash

new_sandbox
ln -s "$REPO/scripts/tests/shim.sh" "$T/bin/xcodebuild"

PIN_HELPER="$REPO/scripts/release/pin-helper.sh"
HELPER_ID="io.github.ivanhernandez-dev.overtime.helper"
FAKE="$T/fake/OvertimeHelper"

pin_lib() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    . "$REPO/scripts/release/lib/pin.sh"
    . "$REPO/scripts/release/lib/verify.sh"
    ot_load_pins
    "$@"
  )
}

HV="$(pin_lib ot_helper_version)"
V="$(pin_lib ot_marketing_version)"
PIN_ROOT="$T/pin"
PIN_DIR="$PIN_ROOT/v$HV"
MANIFEST="$PIN_DIR/MANIFEST.json"
PIN_LOG="$T/pin.log"
SOURCE_PATHS="Packages/OvertimeRuntime/Sources/OvertimeHelperCore
Packages/OvertimeRuntime/Sources/overtime-helper
Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.dev.helper.plist
Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.helper.plist"

mkdir "$T/fake"
printf 'int main(void) { return 0; }\n' > "$T/fake/main.c"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=14.0 -o "$FAKE" "$T/fake/main.c" > "$T/fake/clang.log" 2>&1
XCODE_BUILD="$(/usr/bin/xcrun xcodebuild -version 2> /dev/null | sed -n 's/^Build version //p')"
shim_allow_sub xcodebuild -version 0 "$(printf 'Xcode 27.0\nBuild version %s\n' "$XCODE_BUILD")"

field() {
  jq -r "$1" "${2:-$MANIFEST}"
}

shim_allow_sub git status 0 ""
/bin/bash "$PIN_HELPER" --identity - --helper "$FAKE" --out "$PIN_DIR" > "$PIN_LOG" 2>&1
PIN_STATUS=$?
find "$SHIM_DIR" -name 'git.status.*' -delete
if [ "$PIN_STATUS" -ne 0 ]; then
  tail -20 "$PIN_LOG" | sed 's/^/      > /'
fi

pin_wrote_both_files() {
  [ -f "$PIN_DIR/OvertimeHelper" ] && [ -s "$MANIFEST" ]
}

version_matches_source() {
  [ "$(field '.helperVersion | type')" = "number" ] && [ -n "$HV" ] && [ "$(field '.helperVersion')" = "$HV" ]
}

hashes_match_pinned_file() {
  local cdhash
  cdhash="$(codesign -dvvv "$PIN_DIR/OvertimeHelper" 2>&1 | sed -n 's/^CDHash=//p')"
  [ -n "$cdhash" ] && [ "$(field '.cdhash')" = "$cdhash" ] \
    && [ "$(field '.sha256')" = "$(shasum -a 256 "$PIN_DIR/OvertimeHelper" | awk '{ print $1 }')" ]
}

identity_fields_match() {
  [ "$(field '.identifier')" = "$HELPER_ID" ] \
    && [ "$(field '.sourceCommit')" = "$("$REAL_GIT" -C "$REPO" rev-parse HEAD)" ] \
    && [ "$(field '.xcodeBuild')" = "$XCODE_BUILD" ] && [ -n "$XCODE_BUILD" ] \
    && [[ "$(field '.date')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

sources_match_head() {
  local path
  [ "$(field '.sources | keys | join("\n")')" = "$SOURCE_PATHS" ] || return 1
  while IFS= read -r path; do
    [ "$(jq -r --arg path "$path" '.sources[$path]' "$MANIFEST")" = "$("$REAL_GIT" -C "$REPO" rev-parse "HEAD:$path")" ] \
      || { printf 'mismatch: %s\n' "$path"; return 1; }
  done <<< "$SOURCE_PATHS"
}

pinned_signature_is_helper_runtime() {
  local info
  codesign --verify --strict "$PIN_DIR/OvertimeHelper" || return 1
  info="$(codesign -dvvv "$PIN_DIR/OvertimeHelper" 2>&1)"
  printf '%s\n' "$info" | grep -qx "Identifier=$HELPER_ID" \
    && [[ "$info" =~ flags=0x[0-9a-fA-F]+\([^\)]*runtime[^\)]*\) ]]
}

entitlement_bytes() {
  codesign -d --entitlements - --xml "$1" 2> /dev/null | wc -c | tr -d ' '
}

pinned_has_no_entitlements() {
  local control="$T/entitled-control"
  [ -f "$PIN_DIR/OvertimeHelper" ] || return 1
  cp "$FAKE" "$control"
  codesign --force --options runtime --timestamp=none -s - \
    --entitlements "$REPO/Resources/Overtime-T1.entitlements" "$control" > /dev/null 2>&1
  [ "$(entitlement_bytes "$control")" -gt 0 ] && [ "$(entitlement_bytes "$PIN_DIR/OvertimeHelper")" -eq 0 ]
}

run_check_mode() {
  /bin/bash "$PIN_HELPER" --check "$@"
}

prints_current() {
  local output
  output="$(run_check_mode --pin-root "$PIN_ROOT")" || return 1
  printf '%s\n' "$output"
  [ "$output" = "pin: current" ]
}

variant() {
  local name="$1" filter="$2"
  mkdir -p "$T/$name/v$HV"
  cp "$PIN_DIR/OvertimeHelper" "$T/$name/v$HV/OvertimeHelper"
  jq "$filter" "$MANIFEST" > "$T/$name/v$HV/MANIFEST.json"
  printf '%s\n' "$T/$name"
}

check_fails_naming() {
  local root="$1" pattern="$2" output status
  output="$(run_check_mode --pin-root "$root" 2>&1)"
  status=$?
  printf '%s\n' "$output"
  [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -q '^pin: FAILED: ' \
    && printf '%s\n' "$output" | grep -qF -- "$pattern" && ! printf '%s\n' "$output" | grep -qx 'pin: current'
}

WRONG_ID_ROOT="$(variant wrong-id \
  '.sources["Packages/OvertimeRuntime/Sources/overtime-helper"] = "0000000000000000000000000000000000000000"')"
MISSING_KEY_ROOT="$(variant missing-key \
  'del(.sources["Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.dev.helper.plist"])')"
EXTRA_KEY_ROOT="$(variant extra-key '.sources["Packages/OvertimeRuntime/Sources/OvertimeHelperClient"] = "0"')"
VERSION_ROOT="$(variant version ".helperVersion = $((HV + 1))")"
FLIPPED_ROOT="$(variant flipped '.')"
pin_lib ot_tamper_last_byte "$FLIPPED_ROOT/v$HV/OvertimeHelper"
mkdir "$T/empty-root"

no_pin_yet_fails() {
  local output status
  output="$(run_check_mode --pin-root "$T/empty-root" 2>&1)"
  status=$?
  printf '%s\n' "$output"
  [ "$status" -eq 1 ] && printf '%s\n' "$output" | grep -qx "pin: no pin yet for helper version $HV"
}

no_pin_yet_allowed() {
  local output
  output="$(run_check_mode --allow-missing --pin-root "$T/empty-root")" || return 1
  [ "$output" = "pin: no pin yet for helper version $HV" ]
}

pin_helper_exits_with() {
  local code="$1" status
  shift
  /bin/bash "$PIN_HELPER" "$@" > "$T/usage.log" 2>&1
  status=$?
  [ "$status" -eq "$code" ] || { cat "$T/usage.log"; return 1; }
}

mkdir "$T/busy"
: > "$T/busy/leftover"

mkdir "$T/refuse-bin"
ln -s "$REPO/scripts/tests/shim.sh" "$T/refuse-bin/codesign"

release_refuses_without_pin() {
  local repo="$1" log="$T/release-$2.log" status
  env PATH="$T/refuse-bin:$PATH" SPARKLE_ED_PRIVATE_KEY=not-a-key /bin/bash "$repo/scripts/release/release.sh" \
    --identity 0000000000000000000000000000000000000000 --version "$V" --out "$T/out-$2" > "$log" 2>&1
  status=$?
  cat "$log"
  [ "$status" -eq 1 ] && ! grep -q '^stage: build' "$log" \
    && grep -qx "pin: no pin yet for helper version $HV" "$log" \
    && grep -qxF 'release: error: a release needs a current helper pin under Pinned/helper (pin-helper.sh)' "$log" \
    && no_shim_calls codesign
}

NO_PIN_REPO="$T/no-pin-repo"
HELPER_IDENTITY_SOURCE="Packages/OvertimeRuntime/Sources/OvertimeHelperCore/HelperIdentity.swift"
mkdir -p "$NO_PIN_REPO/scripts" "$NO_PIN_REPO/$(dirname "$HELPER_IDENTITY_SOURCE")"
cp -R "$REPO/scripts/release" "$NO_PIN_REPO/scripts/release"
cp "$REPO/project.yml" "$NO_PIN_REPO/project.yml"
cp "$REPO/$HELPER_IDENTITY_SOURCE" "$NO_PIN_REPO/$HELPER_IDENTITY_SOURCE"

HELPER_CORE="Packages/OvertimeRuntime/Sources/OvertimeHelperCore"
DIRTY_LINE='release: error: the helper sources have uncommitted changes; pin from a clean checkout'

helper_tree() {
  local dest="$T/tree-$1" path
  mkdir -p "$dest/scripts"
  cp -R "$REPO/scripts/release" "$dest/scripts/release"
  cp "$REPO/project.yml" "$dest/project.yml"
  while IFS= read -r path; do
    mkdir -p "$dest/$(dirname "$path")"
    cp -R "$REPO/$path" "$dest/$path"
  done <<< "$SOURCE_PATHS"
  "$REAL_GIT" -C "$dest" init -q && "$REAL_GIT" -C "$dest" add -A \
    && "$REAL_GIT" -C "$dest" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
      commit -q -m fixture > /dev/null
}

pin_from_tree() {
  /bin/bash "$T/tree-$1/scripts/release/pin-helper.sh" --identity - --helper "$FAKE" --out "$T/pins-$1/v$HV" \
    > "$T/pin-$1.log" 2>&1
}

pins_from_tree() {
  pin_from_tree "$1" || { cat "$T/pin-$1.log"; return 1; }
  [ -s "$T/pins-$1/v$HV/MANIFEST.json" ] && ! grep -qF "$DIRTY_LINE" "$T/pin-$1.log"
}

refuses_dirty_tree() {
  local status
  pin_from_tree "$1"
  status=$?
  cat "$T/pin-$1.log"
  [ "$status" -eq 1 ] && grep -qxF "$DIRTY_LINE" "$T/pin-$1.log" && grep -qF -- "$2" "$T/pin-$1.log" \
    && [ ! -e "$T/pins-$1" ]
}

helper_tree clean
helper_tree modified && printf '\n' >> "$T/tree-modified/$HELPER_CORE/HelperIdentity.swift"
helper_tree staged && printf 'let planted = 1\n' > "$T/tree-staged/$HELPER_CORE/Planted.swift" \
  && "$REAL_GIT" -C "$T/tree-staged" add "$HELPER_CORE/Planted.swift"
helper_tree plist \
  && printf '\n' >> "$T/tree-plist/Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.helper.plist"
helper_tree untracked && printf 'let planted = 1\n' > "$T/tree-untracked/$HELPER_CORE/Planted.swift"
helper_tree outside && printf '\n' >> "$T/tree-outside/project.yml"

mkdir -p "$T/app/Overtime.app/Contents/MacOS" "$T/explicit/Overtime.app/Contents/MacOS"
cp "$PIN_DIR/OvertimeHelper" "$T/app/Overtime.app/Contents/MacOS/OvertimeHelper" 2> /dev/null
EXPLICIT_HELPER="$T/explicit/Overtime.app/Contents/MacOS/OvertimeHelper"
cp "$FAKE" "$EXPLICIT_HELPER"
codesign --force --options runtime --timestamp=none -i "$HELPER_ID" -r="designated => identifier \"$HELPER_ID\"" \
  -s - "$EXPLICIT_HELPER" > /dev/null 2>&1

requirement_passes_when_equal() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    . "$REPO/scripts/release/lib/pin.sh"
    . "$REPO/scripts/release/lib/verify.sh"
    ot_load_pins
    HELPER_DESIGNATED_REQUIREMENT="identifier \"$HELPER_ID\""
    ot_check_helper_requirement "$T/explicit/Overtime.app"
  )
}

requirement_fails_for_adhoc() {
  local output status
  output="$(pin_lib ot_check_helper_requirement "$T/app/Overtime.app" 2>&1)"
  status=$?
  printf '%s\n' "$output"
  [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -q '^verify: helper requirement FAILED'
}

check "pin-helper.sh --identity - --helper --out exits 0" test "$PIN_STATUS" -eq 0
check "the pin folder holds OvertimeHelper and MANIFEST.json" pin_wrote_both_files
check "helperVersion is the number in HelperIdentity.version" version_matches_source
check "sha256 and cdhash match the pinned file" hashes_match_pinned_file
check "identifier, sourceCommit, xcodeBuild and date are recorded" identity_fields_match
check "sources are exactly the four helper paths, each with its git id at HEAD" sources_match_head
check "the pinned binary is strictly valid, carries the helper identifier and the runtime flag" \
  pinned_signature_is_helper_runtime
check "the pinned binary has a zero-byte entitlements read beside an entitled control" pinned_has_no_entitlements
check "--check against the fresh pin prints pin: current" prints_current
check "a wrong id for the overtime-helper folder fails naming that path" \
  check_fails_naming "$WRONG_ID_ROOT" "Packages/OvertimeRuntime/Sources/overtime-helper"
check "a manifest missing one source key fails" \
  check_fails_naming "$MISSING_KEY_ROOT" "io.github.ivanhernandez-dev.overtime.dev.helper.plist"
check "a manifest with an extra source key fails" \
  check_fails_naming "$EXTRA_KEY_ROOT" "Packages/OvertimeRuntime/Sources/OvertimeHelperClient"
check "a pinned binary with one flipped byte fails" check_fails_naming "$FLIPPED_ROOT" "sha256"
check "a manifest helperVersion one above HelperIdentity.version fails" check_fails_naming "$VERSION_ROOT" "HelperIdentity.version"
check "an empty pin root fails with pin: no pin yet for helper version $HV" no_pin_yet_fails
check "an empty pin root passes with --allow-missing" no_pin_yet_allowed
check "pin mode without --identity exits 64" pin_helper_exits_with 64 --helper "$FAKE" --out "$T/no-identity"
check "a non-empty --out exits 64" pin_helper_exits_with 64 --identity - --helper "$FAKE" --out "$T/busy"
check "no mode exits 64" pin_helper_exits_with 64
check "--check with --identity exits 64" pin_helper_exits_with 64 --check --identity -
check "an identity that is neither - nor 40 hex exits 64" \
  pin_helper_exits_with 64 --identity "Overtime T1" --helper "$FAKE" --out "$T/bad-identity"
check "a release from a tree with no pin refuses before building, naming the missing pin" \
  release_refuses_without_pin "$NO_PIN_REPO" fixture
if [ -e "$REPO/Pinned/helper/v$HV" ]; then
  printf 'skip  the real repository has a pin for helper version %s, so its no-pin refusal is not checked\n' "$HV"
else
  check "a real release refuses before building while the repository has no pin" release_refuses_without_pin "$REPO" real
fi
check "pin mode from a clean checkout writes the pin" pins_from_tree clean
check "pin mode refuses an uncommitted edit in OvertimeHelperCore and writes nothing" \
  refuses_dirty_tree modified "$HELPER_CORE/HelperIdentity.swift"
check "pin mode refuses a staged new file in OvertimeHelperCore and writes nothing" \
  refuses_dirty_tree staged "$HELPER_CORE/Planted.swift"
check "pin mode refuses an uncommitted edit to the helper's launchd plist and writes nothing" \
  refuses_dirty_tree plist "io.github.ivanhernandez-dev.overtime.helper.plist"
check "pin mode ignores an untracked file, which the build never copies" pins_from_tree untracked
check "pin mode ignores an uncommitted edit outside the helper sources" pins_from_tree outside
check "the helper requirement check passes when the DR equals the expected string" requirement_passes_when_equal
check "the ad-hoc helper fails the real-mode helper requirement check" requirement_fails_for_adhoc
check "no gh, brew, security, defaults, sudo or launchctl call was made" \
  no_shim_calls gh brew security defaults sudo launchctl
