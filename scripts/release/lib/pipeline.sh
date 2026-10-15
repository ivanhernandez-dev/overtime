#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OT_SPM_DIR="${OT_SPM_DIR:-$REPO/.build/spm}"
OT_SPARKLE_ARTIFACT="$OT_SPM_DIR/artifacts/sparkle/Sparkle"

ot_die() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

ot_fail() {
  printf 'release: error: %s\n' "$*" >&2
  return 1
}

ot_load_pins() {
  . "$REPO/scripts/release/pins.env"
}

ot_require_tools() {
  local tool version
  for tool in git tar xcodegen xcodebuild xcrun jq codesign lipo vtool plutil ditto hdiutil shasum ruby; do
    command -v "$tool" > /dev/null 2>&1 || ot_fail "missing tool: $tool" || return 1
  done
  version="$(xcodegen --version 2> /dev/null | sed -n 's/^Version: //p')"
  [ "$version" = "$XCODEGEN_VERSION" ] || ot_fail "xcodegen $version, expected $XCODEGEN_VERSION"
}

ot_project_setting() {
  awk -v key="$1" '$1 == key ":" { print $2; exit }' "$REPO/project.yml"
}

ot_marketing_version() {
  ot_project_setting MARKETING_VERSION
}

ot_project_build() {
  ot_project_setting CURRENT_PROJECT_VERSION
}

ot_build_number() {
  local version="${1:-}"
  local pattern='^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$'
  if [[ ! "$version" =~ $pattern ]]; then
    ot_fail "invalid version '$version' (expected X.Y.Z, each part 0 to 99 with no leading zero)"
    return 1
  fi
  printf '%s\n' "$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3]))"
}

ot_check_release_version() {
  local version="$1" marketing="$2" build="$3" derived
  derived="$(ot_build_number "$version")" || return 1
  [ "$version" = "$marketing" ] || ot_fail "version $version differs from MARKETING_VERSION $marketing" || return 1
  [ "$build" = "$derived" ] || ot_fail "project build $build differs from the derived build $derived" || return 1
}

ot_generate_project() {
  local out="$1"
  mkdir -p "$out/xcode" "$out/logs"
  (cd "$REPO" && git ls-files -z) > "$out/logs/sources.list" || ot_fail "listing the tracked files failed" || return 1
  (cd "$REPO" && tar --null -T "$out/logs/sources.list" -cf -) | (cd "$out/xcode" && tar -xf -) \
    || ot_fail "copying the tracked files failed" || return 1
  xcodegen generate --quiet --spec "$out/xcode/project.yml" > "$out/logs/xcodegen.log" 2>&1 \
    || { tail -20 "$out/logs/xcodegen.log" >&2; ot_fail "xcodegen failed"; }
}

ot_resolve_packages() {
  local out="$1"
  mkdir -p "$out/logs"
  xcodebuild -resolvePackageDependencies -project "$out/xcode/Overtime.xcodeproj" -scheme Overtime \
    -derivedDataPath "$out/dd" -clonedSourcePackagesDirPath "$OT_SPM_DIR" > "$out/logs/resolve.log" 2>&1 \
    || { tail -20 "$out/logs/resolve.log" >&2; ot_fail "package resolution failed"; }
}

ot_sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

ot_check_sparkle_pin() {
  local out="$1"
  local resolved="$out/xcode/Overtime.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local revision version digest
  [ -f "$resolved" ] || ot_fail "no Package.resolved at $resolved" || return 1
  revision="$(jq -r '[.pins[] | select(.identity == "sparkle")][0].state.revision // empty' "$resolved")"
  version="$(jq -r '[.pins[] | select(.identity == "sparkle")][0].state.version // empty' "$resolved")"
  [ "$revision" = "$SPARKLE_REVISION" ] || ot_fail "Sparkle revision '$revision', expected $SPARKLE_REVISION" || return 1
  [ "$version" = "$SPARKLE_VERSION" ] || ot_fail "Sparkle version '$version', expected $SPARKLE_VERSION" || return 1
  [ -f "$OT_SPARKLE_ARTIFACT/bin/generate_appcast" ] || ot_fail "no generate_appcast in $OT_SPARKLE_ARTIFACT/bin" || return 1
  [ -f "$OT_SPARKLE_ARTIFACT/bin/sign_update" ] || ot_fail "no sign_update in $OT_SPARKLE_ARTIFACT/bin" || return 1
  digest="$(ot_sha256 "$OT_SPARKLE_ARTIFACT/bin/generate_appcast")"
  [ "$digest" = "$SPARKLE_GENERATE_APPCAST_SHA256" ] || ot_fail "generate_appcast sha256 $digest differs from the pin" || return 1
  digest="$(ot_sha256 "$OT_SPARKLE_ARTIFACT/bin/sign_update")"
  [ "$digest" = "$SPARKLE_SIGN_UPDATE_SHA256" ] || ot_fail "sign_update sha256 $digest differs from the pin" || return 1
  printf 'pin: Sparkle %s at %s, tool digests ok\n' "$version" "$revision"
}

ot_build_release() {
  local out="$1" version="$2" build="$3" public_key="$4"
  local product="$out/dd/Build/Products/Release/Overtime.app"
  mkdir -p "$out/logs"
  xcodebuild build -project "$out/xcode/Overtime.xcodeproj" -scheme Overtime -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$out/dd" -clonedSourcePackagesDirPath "$OT_SPM_DIR" \
    -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" SPARKLE_PUBLIC_ED_KEY="$public_key" > "$out/logs/build.log" 2>&1 \
    || { grep -E 'error:|BUILD FAILED' "$out/logs/build.log" | tail -20 >&2; ot_fail "xcodebuild failed"; return 1; }
  [ -d "$product" ] || ot_fail "no product at $product" || return 1
  mkdir "$out/app"
  ditto "$product" "$out/app/Overtime.app" || ot_fail "copying the product failed" || return 1
  printf '%s\n' "$out/app/Overtime.app"
}

ot_sparkle_versions_dir() {
  printf '%s\n' "$1/Contents/Frameworks/Sparkle.framework/Versions/B"
}

ot_thin_sparkle() {
  local app="$1" framework binary mode archs
  framework="$(ot_sparkle_versions_dir "$app")"
  for binary in "$framework/Sparkle" "$framework/Autoupdate" "$framework/Updater.app/Contents/MacOS/Updater" \
    "$framework/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$framework/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
    [ -f "$binary" ] || ot_fail "missing Sparkle binary $binary" || return 1
    archs="$(lipo -archs "$binary")" || ot_fail "lipo cannot read $binary" || return 1
    if [ "$archs" = "arm64" ]; then
      continue
    fi
    mode="$(stat -f '%Lp' "$binary")"
    lipo -thin arm64 "$binary" -output "$binary.thin" || ot_fail "thinning $binary failed" || return 1
    mv -f "$binary.thin" "$binary"
    chmod "$mode" "$binary"
    printf 'thin: %s\n' "${binary#"$app"/}"
  done
}

ot_sign_inside_out() {
  local app="$1" identity="$2" framework
  framework="$(ot_sparkle_versions_dir "$app")"
  local sign=(codesign --force --options runtime --timestamp=none -s "$identity")
  "${sign[@]}" "$framework/XPCServices/Installer.xpc" || return 1
  "${sign[@]}" --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc" || return 1
  "${sign[@]}" "$framework/Autoupdate" || return 1
  "${sign[@]}" "$framework/Updater.app" || return 1
  "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework" || return 1
  "${sign[@]}" -i "$SENTINEL_IDENTIFIER" "$app/Contents/MacOS/overtime-sentinel" || return 1
  "${sign[@]}" --entitlements "$REPO/Resources/Overtime-T1.entitlements" "$app" || return 1
}

ot_zip() {
  local app="$1" out="$2" version="$3"
  mkdir -p "$out/dist"
  ditto -c -k --keepParent "$app" "$out/dist/Overtime-$version.zip" || ot_fail "zip failed"
}

ot_dmg() {
  local app="$1" out="$2" version="$3" stage
  mkdir -p "$out/dist" "$out/logs"
  stage="$(mktemp -d "$out/dmg.XXXXXX")"
  ditto "$app" "$stage/Overtime.app" || ot_fail "staging the DMG failed" || return 1
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname Overtime -srcfolder "$stage" -ov -format ULFO "$out/dist/Overtime-$version.dmg" \
    > "$out/logs/dmg.log" 2>&1 || { tail -20 "$out/logs/dmg.log" >&2; ot_fail "hdiutil create failed"; }
}

ot_notes() {
  local out="$1" version="$2"
  local notes="$out/notes-$version.md"
  awk -v heading="## [$version]" '
    index($0, heading) == 1 { on = 1; next }
    on && index($0, "## [") == 1 { exit }
    on { lines[++n] = $0 }
    END {
      first = 1
      while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$REPO/CHANGELOG.md" > "$notes"
  [ -s "$notes" ] || ot_fail "CHANGELOG.md has no section for $version, or it is empty"
}

ot_build_edkey() {
  local out="$1"
  mkdir -p "$out/tools" "$out/logs"
  xcrun swiftc -O -warnings-as-errors -module-cache-path "$out/modcache" -o "$out/tools/edkey" \
    "$REPO/scripts/release/edkey.swift" > "$out/logs/edkey.log" 2>&1 \
    || { tail -20 "$out/logs/edkey.log" >&2; ot_fail "building edkey failed"; }
}

ot_dry_run_key() {
  local out="$1" key="$1/keys/dry-run-ed25519.txt"
  (umask 077 && mkdir "$out/keys" && head -c 32 /dev/urandom | base64 > "$key") \
    || ot_fail "creating the dry-run key failed" || return 1
  chmod 600 "$key"
  printf '%s\n' "$key"
}

ot_tamper_title() {
  awk '!done && sub(/<title>O/, "<title>Q") { done = 1 } { print }' "$1" > "$2"
}

ot_tamper_last_byte() {
  local file="$1" size last
  size="$(stat -f '%z' "$file")"
  last="$(tail -c 1 "$file" | od -An -tu1 | tr -d ' ')"
  if [ "$last" = "1" ]; then
    printf '\002' | dd of="$file" bs=1 seek="$((size - 1))" conv=notrunc 2> /dev/null
  else
    printf '\001' | dd of="$file" bs=1 seek="$((size - 1))" conv=notrunc 2> /dev/null
  fi
}

ot_appcast() {
  local out="$1" version="$2" app="$3" keysource="$4"
  local zip="Overtime-$version.zip" stage log count
  local edkey="$out/tools/edkey" plist="$app/Contents/Info.plist"
  log="$out/logs/appcast.log"
  stage="$(mktemp -d "$out/appcast.XXXXXX")"
  mkdir -p "$out/home" "$out/logs"
  cp "$out/dist/$zip" "$stage/$zip"
  cp "$out/notes-$version.md" "$stage/Overtime-$version.md"
  if [ "$keysource" = "env" ]; then
    printf '%s\n' "${SPARKLE_ED_PRIVATE_KEY:?}" | CFFIXED_USER_HOME="$out/home" \
      "$OT_SPARKLE_ARTIFACT/bin/generate_appcast" --ed-key-file - \
      --download-url-prefix "$DOWNLOAD_URL_BASE/v$version/" --embed-release-notes --maximum-deltas 0 "$stage" \
      > "$log" 2>&1 || { tail -20 "$log" >&2; ot_fail "generate_appcast failed"; return 1; }
  else
    CFFIXED_USER_HOME="$out/home" "$OT_SPARKLE_ARTIFACT/bin/generate_appcast" --ed-key-file - \
      --download-url-prefix "$DOWNLOAD_URL_BASE/v$version/" --embed-release-notes --maximum-deltas 0 "$stage" \
      < "$keysource" > "$log" 2>&1 || { tail -20 "$log" >&2; ot_fail "generate_appcast failed"; return 1; }
  fi
  if grep -qi "does not match" "$log"; then
    grep -i "does not match" "$log" >&2
    ot_fail "generate_appcast reports a key that does not match the app"
    return 1
  fi
  [ -f "$stage/appcast.xml" ] || ot_fail "generate_appcast wrote no appcast.xml" || return 1
  count="$(grep -o '<item>' "$stage/appcast.xml" | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || ot_fail "appcast has $count items, expected 1" || return 1
  count="$(grep -o 'sparkle:edSignature' "$stage/appcast.xml" | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || ot_fail "appcast has $count sparkle:edSignature, expected 1" || return 1
  grep -q '<!-- sparkle-signatures:' "$stage/appcast.xml" || ot_fail "appcast is not a signed feed" || return 1
  "$edkey" verify-feed "$plist" "$stage/appcast.xml" "$stage/$zip" || ot_fail "edkey verification failed" || return 1
  if [ "$keysource" != "env" ]; then
    CFFIXED_USER_HOME="$out/home" "$OT_SPARKLE_ARTIFACT/bin/sign_update" --verify --ed-key-file - \
      "$stage/appcast.xml" < "$keysource" || ot_fail "sign_update rejected the feed" || return 1
    printf 'appcast: sign_update verified the feed\n'
  fi
  mkdir -p "$out/selftest"
  ot_tamper_title "$stage/appcast.xml" "$out/selftest/appcast.xml"
  cp "$stage/$zip" "$out/selftest/$zip"
  ot_tamper_last_byte "$out/selftest/$zip"
  if cmp -s "$stage/appcast.xml" "$out/selftest/appcast.xml" || cmp -s "$stage/$zip" "$out/selftest/$zip"; then
    ot_fail "the negative-control copies are not tampered"
    return 1
  fi
  if "$edkey" verify-feed "$plist" "$out/selftest/appcast.xml" "$stage/$zip" > /dev/null 2>&1; then
    ot_fail "a tampered feed passed verification"
    return 1
  fi
  if "$edkey" verify-feed "$plist" "$stage/appcast.xml" "$out/selftest/$zip" > /dev/null 2>&1; then
    ot_fail "a tampered archive passed verification"
    return 1
  fi
  printf 'appcast: negative controls failed as expected\n'
  mkdir -p "$out/dist"
  cp "$stage/appcast.xml" "$out/dist/appcast.xml"
  cmp -s "$stage/appcast.xml" "$out/dist/appcast.xml" || ot_fail "appcast.xml changed while copying"
}

ot_checksums() {
  local out="$1" version="$2"
  (cd "$out/dist" && shasum -a 256 "Overtime-$version.dmg" "Overtime-$version.zip" appcast.xml > SHA256SUMS) \
    || ot_fail "checksums failed"
}
