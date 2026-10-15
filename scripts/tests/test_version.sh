#!/bin/bash

new_sandbox
ln -s "$REPO/scripts/tests/shim.sh" "$T/bin/xcodebuild"
ln -s "$REPO/scripts/tests/shim.sh" "$T/bin/codesign"

FAKE_IDENTITY="0000000000000000000000000000000000000000"
RELEASE_LOG="$T/release.log"

pipeline() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    ot_load_pins
    "$@"
  )
}

build_number_is() {
  [ "$(pipeline ot_build_number "$1")" = "$2" ]
}

release_exits_with() {
  local code="$1" status
  shift
  /bin/bash "$REPO/scripts/release/release.sh" "$@" > "$RELEASE_LOG" 2>&1
  status=$?
  [ "$status" -eq "$code" ] || { cat "$RELEASE_LOG"; return 1; }
}

V="$(pipeline ot_marketing_version)"
if [ "$V" = "0.1.1" ]; then OTHER="0.1.2"; else OTHER="0.1.1"; fi

refused_before_build() {
  local status="$1" reason="$2"
  [ "$status" -eq 1 ] && ! grep -q '^stage: build' "$RELEASE_LOG" \
    && [ "$(grep -c '^release: error: ' "$RELEASE_LOG")" -eq 1 ] \
    && grep -qxF "release: error: $reason" "$RELEASE_LOG" || { cat "$RELEASE_LOG"; return 1; }
}

release_without_key_refuses() {
  local reason="$1"
  shift
  env -u SPARKLE_ED_PRIVATE_KEY /bin/bash "$REPO/scripts/release/release.sh" "$@" > "$RELEASE_LOG" 2>&1
  refused_before_build "$?" "$reason"
}

release_with_key_refuses() {
  local reason="$1"
  shift
  env SPARKLE_ED_PRIVATE_KEY=not-a-key /bin/bash "$REPO/scripts/release/release.sh" "$@" > "$RELEASE_LOG" 2>&1
  refused_before_build "$?" "$reason"
}

gh_is_refused_and_logged() {
  gh release list
  [ "$?" -eq 97 ] && shim_calls gh | grep -qx 'release list'
}

allowed_call_runs() {
  shim_allow_sub gh auth 0 "allowed"
  [ "$(gh auth status)" = "allowed" ]
}

check_fails "the harness refuses an unlisted gh call" gh release view
check "the refused call exits 97 and is logged" gh_is_refused_and_logged
check "the harness runs an allowed call" allowed_call_runs

check "0.1.0 builds 100" build_number_is 0.1.0 100
check "1.2.3 builds 10203" build_number_is 1.2.3 10203
check "0.0.1 builds 1" build_number_is 0.0.1 1
check "99.99.99 builds 999999" build_number_is 99.99.99 999999
check_fails "0.100.0 is rejected" pipeline ot_build_number 0.100.0
check_fails "1.2 is rejected" pipeline ot_build_number 1.2
check_fails "1.2.3-rc1 is rejected" pipeline ot_build_number 1.2.3-rc1
check_fails "01.2.3 is rejected" pipeline ot_build_number 01.2.3
check_fails "v1.2.3 is rejected" pipeline ot_build_number v1.2.3
check_fails "the empty version is rejected" pipeline ot_build_number ""
check_fails "a version with a second line is rejected" pipeline ot_build_number "$(printf '1.2.3\n4.5.6')"

check "a release of 0.1.0 with MARKETING_VERSION 0.1.0 and build 100 is accepted" \
  pipeline ot_check_release_version 0.1.0 0.1.0 100
check_fails "a version that differs from MARKETING_VERSION is refused" \
  pipeline ot_check_release_version 0.1.1 0.1.0 100
check_fails "a project build that differs from the derivation is refused" \
  pipeline ot_check_release_version 0.1.0 0.1.0 1

check "release.sh with no mode exits 64" release_exits_with 64
check "release.sh with an unknown flag exits 64" release_exits_with 64 --dry-run --publish
check "the real mode without --identity exits 64" release_exits_with 64 --version 0.1.0
check "the real mode without --version exits 64" release_exits_with 64 --identity "$FAKE_IDENTITY"
check "the real mode with a malformed identity exits 64" release_exits_with 64 --identity "Overtime T1" --version 0.1.0
check "--dry-run with --identity exits 64" release_exits_with 64 --dry-run --identity "$FAKE_IDENTITY"
check "the real mode at MARKETING_VERSION without SPARKLE_ED_PRIVATE_KEY exits 1 before building, naming the key" \
  release_without_key_refuses "SPARKLE_ED_PRIVATE_KEY is not set" \
  --identity "$FAKE_IDENTITY" --version "$V" --out "$T/out-nokey"
check "the real mode with a version other than MARKETING_VERSION exits 1 before building, naming the version" \
  release_with_key_refuses "version $OTHER differs from MARKETING_VERSION $V" \
  --identity "$FAKE_IDENTITY" --version "$OTHER" --out "$T/out-version"
mkdir "$T/busy"
: > "$T/busy/leftover"
check "a non-empty --out folder exits 64" release_exits_with 64 --dry-run --out "$T/busy"
check "no xcodebuild or codesign call was made" no_shim_calls xcodebuild codesign
