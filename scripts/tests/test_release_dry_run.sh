#!/bin/bash

new_sandbox

release_value() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    . "$REPO/scripts/release/lib/pin.sh"
    "$@"
  )
}

V="$(release_value ot_marketing_version)"
BUILD="$(release_value ot_build_number "$V")"
HV="$(release_value ot_helper_version)"
if [ "$V" = "0.1.1" ]; then OTHER="0.1.2"; else OTHER="0.1.1"; fi
OTHER_BUILD="$(release_value ot_build_number "$OTHER")"
OUT="$T/out"
DIST="$OUT/dist"
APP="$OUT/app/Overtime.app"
RELEASE_LOG="$T/release.log"
REAL_CACHE="$REAL_HOME/Library/Caches/Sparkle_generate_appcast"
SPARKLE_B="Contents/Frameworks/Sparkle.framework/Versions/B"

repo_digests() {
  (cd "$REPO" && shasum -a 256 project.yml Resources/Info.plist Resources/Overtime-T1.entitlements)
}

real_cache_listing() {
  if [ -d "$REAL_CACHE" ]; then
    ls -1A "$REAL_CACHE" | LC_ALL=C sort
  fi
}

attached_images() {
  hdiutil info | sed -n 's/^image-path[[:space:]]*:[[:space:]]*//p' | grep -F -e "$OUT" -e "$T" -e "Overtime-" | LC_ALL=C sort || true
}

repo_digests > "$T/repo-before"
real_cache_listing > "$T/cache-before"
attached_images > "$T/images-before"
/bin/bash "$REPO/scripts/release/release.sh" --dry-run --out "$OUT" > "$RELEASE_LOG" 2>&1
RELEASE_STATUS=$?
attached_images > "$T/images-after"
real_cache_listing > "$T/cache-after"
repo_digests > "$T/repo-after"

if [ "$RELEASE_STATUS" -ne 0 ]; then
  grep -E '^(stage|release|verify|appcast|pin):' "$RELEASE_LOG" | tail -20 | sed 's/^/      > /'
fi

log_starts_with_output() {
  [ "$(head -1 "$RELEASE_LOG")" = "release: output $OUT" ]
}

log_ends_complete() {
  [ "$(tail -1 "$RELEASE_LOG")" = "release: dry-run complete" ]
}

stages_in_order() {
  [ "$(grep '^stage: ' "$RELEASE_LOG" | tr '\n' ' ')" = "stage: build stage: thin stage: sign stage: verify stage: package stage: appcast stage: checksums stage: cask " ]
}

dist_has_assets() {
  [ -s "$DIST/Overtime-$V.zip" ] && [ -s "$DIST/appcast.xml" ] && [ -s "$DIST/SHA256SUMS" ]
}

sums_verify() {
  (cd "$DIST" && shasum -a 256 -c SHA256SUMS)
}

count_of() {
  grep -o "$1" "$2" | wc -l | tr -d ' '
}

one_item_one_signature() {
  [ "$(count_of '<item>' "$DIST/appcast.xml")" = "1" ] \
    && [ "$(count_of 'sparkle:edSignature' "$DIST/appcast.xml")" = "1" ]
}

feed_is_signed() {
  awk '{ text = text $0 "\n" } END { r = index(text, "</rss>"); s = index(text, "<!-- sparkle-signatures:"); exit !(r > 0 && s > r) }' \
    "$DIST/appcast.xml" && [ "$(tail -1 "$DIST/appcast.xml")" = "-->" ]
}

enclosure_url_is_absolute() {
  grep -q "url=\"https://github.com/ivanhernandez-dev/overtime/releases/download/v$V/Overtime-$V.zip\"" \
    "$DIST/appcast.xml"
}

edkey_verifies_feed() {
  "$OUT/tools/edkey" verify-feed "$APP/Contents/Info.plist" "$DIST/appcast.xml" "$DIST/Overtime-$V.zip"
}

sparkle_is_arm64_only() {
  local binary
  for binary in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater \
    XPCServices/Downloader.xpc/Contents/MacOS/Downloader XPCServices/Installer.xpc/Contents/MacOS/Installer; do
    [ "$(lipo -archs "$APP/$SPARKLE_B/$binary")" = "arm64" ] || return 1
  done
}

extracted_zip_verifies() {
  local x="$T/extracted" item
  mkdir "$x" && ditto -x -k "$DIST/Overtime-$V.zip" "$x" || return 1
  for item in "" Contents/Frameworks/Sparkle.framework "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app" \
    "$SPARKLE_B/XPCServices/Downloader.xpc" "$SPARKLE_B/XPCServices/Installer.xpc" \
    Contents/MacOS/overtime-sentinel Contents/MacOS/OvertimeHelper; do
    codesign --verify --strict "$x/Overtime.app/$item" || return 1
  done
}

no_git_writes() {
  ! shim_calls git | grep -Eq '^(push|tag|commit)( |$)'
}

real_cache_untouched() {
  cmp -s "$T/cache-before" "$T/cache-after" && [ -d "$OUT/home/Library/Caches/Sparkle_generate_appcast" ]
}

repo_unchanged() {
  cmp -s "$T/repo-before" "$T/repo-after"
}

key_is_private() {
  local key="$OUT/keys/dry-run-ed25519.txt"
  [ -f "$key" ] && [ "$(stat -f '%Lp' "$key")" = "600" ]
}

check "release.sh --dry-run exits 0" test "$RELEASE_STATUS" -eq 0
check "the first line names the output folder" log_starts_with_output
check "the last line is release: dry-run complete" log_ends_complete
check "the stages run in order" stages_in_order
check "dist holds the zip, appcast.xml and SHA256SUMS" dist_has_assets
check "SHA256SUMS verifies inside dist" sums_verify
check "the appcast has one item and one enclosure signature" one_item_one_signature
check "the appcast ends with the sparkle-signatures comment" feed_is_signed
check "the enclosure URL is the absolute v$V download" enclosure_url_is_absolute
check "edkey verifies the feed and the zip against the built app's key" edkey_verifies_feed
check "every Sparkle Mach-O is arm64-only" sparkle_is_arm64_only
check "the extracted zip passes a strict signature check on every code item" extracted_zip_verifies
check "no gh, brew, security, defaults, sudo, launchctl, pmset or osascript call" \
  no_shim_calls gh brew security defaults sudo launchctl pmset osascript
check "no git push, tag or commit" no_git_writes
check "the real Sparkle_generate_appcast cache is untouched and the fenced one exists" real_cache_untouched
check "project.yml, Info.plist and the entitlements are unchanged" repo_unchanged
check "the dry-run key is mode 600 inside the output keys folder" key_is_private
check "the appcast negative controls failed as expected" \
  grep -qx 'appcast: negative controls failed as expected' "$RELEASE_LOG"

DRY_RUN_KEY="$("$OUT/tools/edkey" pub "$OUT/keys/dry-run-ed25519.txt" 2> /dev/null)"
UNIVERSAL_SPARKLE="$REPO/.build/spm/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Sparkle"

PIN_DIR="$OUT/pin/v$HV"
MANIFEST="$PIN_DIR/MANIFEST.json"

verify_lib() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    . "$REPO/scripts/release/lib/pin.sh"
    . "$REPO/scripts/release/lib/verify.sh"
    ot_load_pins
    "$@"
  )
}

fails_with() {
  local name="$1" output status
  shift
  output="$(verify_lib "$@" 2>&1)"
  status=$?
  printf '%s\n' "$output"
  [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -q "^verify: $name FAILED"
}

tampered_copy() {
  local copy="$T/tamper-$1"
  mkdir "$copy" && ditto "$APP" "$copy/Overtime.app" && printf '%s\n' "$copy/Overtime.app"
}

dmg_is_ulfo() {
  [ -s "$DIST/Overtime-$V.dmg" ] && hdiutil imageinfo "$DIST/Overtime-$V.dmg" | grep -q '^Format: ULFO$'
}

no_image_left_attached() {
  cmp -s "$T/images-before" "$T/images-after"
}

sums_in_order() {
  [ "$(awk '{ print $2 }' "$DIST/SHA256SUMS" | tr '\n' ' ')" = "Overtime-$V.dmg Overtime-$V.zip appcast.xml " ]
}

verify_stage_all_ok() {
  local name
  for name in signatures "runtime flags" "app entitlements" "no get-task-allow" "helper entitlements" \
    architectures "minimum os" "info plist" resources "helper pin"; do
    grep -qx "verify: $name ok" "$RELEASE_LOG" || { printf 'missing: %s\n' "$name"; return 1; }
  done
  grep -qx 'verify: designated requirement skipped: ad-hoc' "$RELEASE_LOG" \
    && grep -qx 'verify: helper requirement skipped: ad-hoc' "$RELEASE_LOG" && ! grep -q 'FAILED' "$RELEASE_LOG"
}

app_entitlements_read() {
  codesign -d --entitlements - --xml "$1" 2> /dev/null | wc -c | tr -d ' '
}

GTA_ENTITLEMENTS="$T/get-task-allow.entitlements"
plutil -convert xml1 -o "$GTA_ENTITLEMENTS" "$REPO/Resources/Overtime-T1.entitlements"
plutil -insert 'com\.apple\.security\.get-task-allow' -bool YES "$GTA_ENTITLEMENTS"

GTA_APP="$(tampered_copy get-task-allow)"
codesign --force --options runtime --timestamp=none -s - --entitlements "$GTA_ENTITLEMENTS" "$GTA_APP" > /dev/null 2>&1

NO_RUNTIME_APP="$(tampered_copy no-runtime)"
codesign --force --timestamp=none -s - --entitlements "$REPO/Resources/Overtime-T1.entitlements" "$NO_RUNTIME_APP" \
  > /dev/null 2>&1

UNIVERSAL_APP="$(tampered_copy universal)"
cp "$UNIVERSAL_SPARKLE" "$UNIVERSAL_APP/$SPARKLE_B/Sparkle"

MINOS_APP="$(tampered_copy minos)"
vtool -set-build-version macos 15.0 27.0 -replace -output "$T/sentinel-minos15" \
  "$MINOS_APP/Contents/MacOS/overtime-sentinel" > /dev/null 2>&1
cp "$T/sentinel-minos15" "$MINOS_APP/Contents/MacOS/overtime-sentinel"

NOTICE_APP="$(tampered_copy notice)"
rm -f "${NOTICE_APP:?}/Contents/Resources/NOTICE"

KEY_APP="$(tampered_copy key)"
PINNED_KEY="$(. "$REPO/scripts/release/pins.env" && printf '%s' "$SPARKLE_PUBLIC_ED_KEY")"
plutil -replace SUPublicEDKey -string "$PINNED_KEY" "$KEY_APP/Contents/Info.plist"

HELPER_APP="$(tampered_copy helper)"
codesign --force --options runtime --timestamp=none -s - --entitlements "$REPO/Resources/Overtime-T1.entitlements" \
  "$HELPER_APP/Contents/MacOS/OvertimeHelper" > /dev/null 2>&1

SEAL_APP="$(tampered_copy seal)"
printf 'tampered\n' >> "$SEAL_APP/Contents/Resources/LICENSE"

helper_tamper_keeps_app_read() {
  [ "$(app_entitlements_read "$HELPER_APP")" -gt 0 ] && [ "$(app_entitlements_read "$HELPER_APP/Contents/MacOS/OvertimeHelper")" -gt 0 ]
}

check "dist holds a ULFO DMG" dmg_is_ulfo
check "no disk image is left attached" no_image_left_attached
check "SHA256SUMS lists the DMG, the zip and appcast.xml in that order" sums_in_order
check "the verify stage printed ok for every check and skipped the DR in dry-run" verify_stage_all_ok
check "verify_all passes on the dry-run bundle" \
  verify_lib ot_verify_all "$APP" dry-run "$V" "$BUILD" "$DRY_RUN_KEY" "$T" "$MANIFEST"
check "a get-task-allow re-sign fails the get-task-allow check" \
  fails_with "no get-task-allow" ot_check_no_get_task_allow "$GTA_APP"
check "a get-task-allow re-sign fails the app entitlements check" \
  fails_with "app entitlements" ot_check_app_entitlements "$GTA_APP"
check "a re-sign without the runtime option fails the runtime check" \
  fails_with "runtime flags" ot_check_runtime_flags "$NO_RUNTIME_APP"
check "a universal Sparkle binary fails the architecture check" \
  fails_with architectures ot_check_architectures "$UNIVERSAL_APP"
check "a minos of 15.0 fails the minimum OS check" fails_with "minimum os" ot_check_minimum_os "$MINOS_APP"
check "a missing NOTICE fails the resources check" fails_with resources ot_check_resources "$NOTICE_APP" "$T"
check "another SUPublicEDKey fails the Info.plist check" \
  fails_with "info plist" ot_check_info_plist "$KEY_APP" "$V" "$BUILD" "$DRY_RUN_KEY"
check "another version fails the Info.plist check" \
  fails_with "info plist" ot_check_info_plist "$APP" "$OTHER" "$OTHER_BUILD" "$DRY_RUN_KEY"
check "an entitled helper fails the helper entitlements check" \
  fails_with "helper entitlements" ot_check_helper_entitlements "$HELPER_APP"
check "the app's entitlement read stays non-empty beside the entitled helper" helper_tamper_keeps_app_read
check "a changed sealed resource fails the signature check" fails_with signatures ot_check_signatures "$SEAL_APP"
check "the ad-hoc designated requirement fails the real-mode DR check" \
  fails_with "designated requirement" ot_check_designated_requirement "$APP" release

pin_manifest_is_current_helper() {
  [ -n "$HV" ] && [ "$(jq -r '.helperVersion' "$MANIFEST")" = "$HV" ] \
    && [ "$(jq -r '.identifier' "$MANIFEST")" = "io.github.ivanhernandez-dev.overtime.helper" ]
}

check "the pin manifest records HelperIdentity.version ($HV) and the helper identifier" pin_manifest_is_current_helper
check "the signed app embeds the pinned helper byte for byte" \
  cmp "$PIN_DIR/OvertimeHelper" "$APP/Contents/MacOS/OvertimeHelper"
check "the verify stage printed verify: helper pin ok" grep -qx 'verify: helper pin ok' "$RELEASE_LOG"
check "the pin negative control failed as expected" \
  grep -qx 'pin: negative control failed as expected' "$RELEASE_LOG"
check "the pinned helper passes its own manifest check" \
  verify_lib ot_pin_check_binary "$PIN_DIR/OvertimeHelper" "$MANIFEST"
check "a re-signed helper fails the helper pin check" \
  fails_with "helper pin" ot_check_helper_pin "$HELPER_APP" "$MANIFEST"
check "a missing manifest fails the helper pin check" \
  fails_with "helper pin" ot_check_helper_pin "$APP" "$T/no-such-pin/MANIFEST.json"

RENDERED_CASK="$OUT/Casks/overtime.rb"

cask_carries_zip_sha() {
  local sha
  sha="$(shasum -a 256 "$DIST/Overtime-$V.zip" | awk '{ print $1 }')"
  [ -n "$sha" ] && grep -qxF "  sha256 \"$sha\"" "$RENDERED_CASK" && grep -qxF "  version \"$V\"" "$RENDERED_CASK"
}

bundled_uninstall_matches() {
  cmp "$REPO/scripts/uninstall.sh" "$APP/Contents/Resources/uninstall.sh" && [ -x "$APP/Contents/Resources/uninstall.sh" ]
}

UNINSTALL_APP="$(tampered_copy uninstall)"
printf '\n' >> "$UNINSTALL_APP/Contents/Resources/uninstall.sh"
MODE_APP="$(tampered_copy uninstall-mode)"
chmod a-x "$MODE_APP/Contents/Resources/uninstall.sh"

check "the cask stage rendered Casks/overtime.rb with the zip's SHA-256" cask_carries_zip_sha
check "the rendered cask passes ruby -c" eval '[ "$(ruby -c "$RENDERED_CASK")" = "Syntax OK" ]'
check "the app bundles uninstall.sh byte-identical and executable" bundled_uninstall_matches
check "a changed bundled uninstall.sh fails the resources check" \
  fails_with resources ot_check_resources "$UNINSTALL_APP" "$T"
check "a non-executable bundled uninstall.sh fails the resources check" \
  fails_with resources ot_check_resources "$MODE_APP" "$T"
