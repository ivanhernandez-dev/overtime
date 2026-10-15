#!/bin/bash
set -euo pipefail

OT_HELPER_IDENTITY_SOURCE="Packages/OvertimeRuntime/Sources/OvertimeHelperCore/HelperIdentity.swift"

ot_helper_version() {
  local file="$REPO/$OT_HELPER_IDENTITY_SOURCE" matches
  matches="$(sed -n 's/^[[:space:]]*public static let version = \([0-9][0-9]*\)[[:space:]]*$/\1/p' "$file" 2> /dev/null || true)"
  if [ -z "$matches" ] || [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != "1" ]; then
    ot_fail "expected one 'public static let version = N' in $OT_HELPER_IDENTITY_SOURCE"
    return 1
  fi
  printf '%s\n' "$matches"
}

ot_pin_source_paths() {
  printf '%s\n' \
    "Packages/OvertimeRuntime/Sources/overtime-helper" \
    "Packages/OvertimeRuntime/Sources/OvertimeHelperCore" \
    "Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.helper.plist" \
    "Resources/LaunchDaemons/io.github.ivanhernandez-dev.overtime.dev.helper.plist"
}

ot_pin_require_clean_sources() {
  local paths=() path dirty
  while IFS= read -r path; do
    paths+=("$path")
  done < <(ot_pin_source_paths)
  dirty="$(cd "$REPO" && git status --porcelain --untracked-files=no -- "${paths[@]}")" \
    || ot_fail "reading the git status of the helper sources failed" || return 1
  [ -z "$dirty" ] && return 0
  printf '%s\n' "$dirty" >&2
  ot_fail "the helper sources have uncommitted changes; pin from a clean checkout"
}

ot_pin_source_id() {
  (cd "$REPO" && git rev-parse --verify --quiet "HEAD:$1")
}

ot_pin_dir() {
  printf '%s/v%s\n' "$1" "$2"
}

ot_code_field() {
  codesign -dvvv "$2" 2>&1 | sed -n "s/^$1=//p" | head -1
}

ot_pin_write() {
  local helper="$1" identity="$2" dir="$3"
  local version sources path id commit build sign_log pinned sha cdhash
  [ -f "$helper" ] || ot_fail "no helper at $helper" || return 1
  if [ -e "$dir" ] && { [ ! -d "$dir" ] || [ -n "$(ls -A "$dir")" ]; }; then
    ot_fail "pin folder $dir must be new or empty"
    return 1
  fi
  version="$(ot_helper_version)" || return 1
  sources='{}'
  while IFS= read -r path; do
    id="$(ot_pin_source_id "$path")" || ot_fail "no git id for $path at HEAD" || return 1
    sources="$(jq -c --arg path "$path" --arg id "$id" '. + {($path): $id}' <<< "$sources")"
  done < <(ot_pin_source_paths)
  commit="$(cd "$REPO" && git rev-parse HEAD)" || ot_fail "reading HEAD failed" || return 1
  build="$(xcodebuild -version 2> /dev/null | sed -n 's/^Build version //p')"
  [ -n "$build" ] || ot_fail "xcodebuild -version printed no build version" || return 1
  mkdir -p "$dir"
  pinned="$dir/OvertimeHelper"
  cp "$helper" "$pinned" || ot_fail "copying the helper failed" || return 1
  chmod 755 "$pinned"
  sign_log="$(codesign --force --options runtime --timestamp=none -i "$HELPER_IDENTIFIER" -s "$identity" "$pinned" 2>&1)" \
    || { printf '%s\n' "$sign_log" >&2; ot_fail "signing the pinned helper failed"; return 1; }
  sha="$(ot_sha256 "$pinned")"
  cdhash="$(ot_code_field CDHash "$pinned")"
  [ -n "$cdhash" ] || ot_fail "no CDHash read from $pinned" || return 1
  jq -n --argjson version "$version" --arg identifier "$HELPER_IDENTIFIER" --arg sha "$sha" --arg cdhash "$cdhash" \
    --arg commit "$commit" --argjson sources "$sources" --arg build "$build" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{helperVersion: $version, identifier: $identifier, sha256: $sha, cdhash: $cdhash, sourceCommit: $commit,
      sources: $sources, xcodeBuild: $build, date: $date}' > "$dir/MANIFEST.json" \
    || ot_fail "writing MANIFEST.json failed" || return 1
  printf 'pin: wrote %s (helper version %s, cdhash %s)\n' "$dir" "$version" "$cdhash"
}

ot_manifest_field() {
  jq -r --arg key "$1" '.[$key] // empty | tostring' "$2" 2> /dev/null || true
}

ot_pin_check_binary() {
  local binary="$1" manifest="$2" failed=0 expected actual
  if [ ! -f "$manifest" ]; then
    printf 'pin: FAILED: no manifest at %s\n' "$manifest"
    return 1
  fi
  if [ ! -f "$binary" ]; then
    printf 'pin: FAILED: no helper binary at %s\n' "$binary"
    return 1
  fi
  expected="$(ot_manifest_field sha256 "$manifest")"
  actual="$(ot_sha256 "$binary")"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    printf 'pin: FAILED: sha256 %s differs from the manifest (%s)\n' "$actual" "${expected:-none}"
    failed=1
  fi
  expected="$(ot_manifest_field cdhash "$manifest")"
  actual="$(ot_code_field CDHash "$binary")"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    printf 'pin: FAILED: cdhash %s differs from the manifest (%s)\n' "${actual:-unreadable}" "${expected:-none}"
    failed=1
  fi
  expected="$(ot_manifest_field identifier "$manifest")"
  actual="$(ot_code_field Identifier "$binary")"
  if [ "$expected" != "$HELPER_IDENTIFIER" ] || [ "$actual" != "$HELPER_IDENTIFIER" ]; then
    printf 'pin: FAILED: identifier %s, manifest %s, expected %s\n' "${actual:-unreadable}" "${expected:-none}" \
      "$HELPER_IDENTIFIER"
    failed=1
  fi
  [ "$failed" -eq 0 ]
}

ot_pin_check_sources() {
  local manifest="$1" failed=0 version recorded path expected actual
  if [ ! -f "$manifest" ]; then
    printf 'pin: FAILED: no manifest at %s\n' "$manifest"
    return 1
  fi
  version="$(ot_helper_version)" || { printf 'pin: FAILED: HelperIdentity.version is unreadable\n'; return 1; }
  recorded="$(jq -r 'if (.helperVersion | type) == "number" then .helperVersion else "invalid" end' "$manifest" \
    2> /dev/null || true)"
  if [ "$recorded" != "$version" ]; then
    printf 'pin: FAILED: the pin is for helper version %s but HelperIdentity.version is %s; re-pin the helper\n' \
      "${recorded:-unreadable}" "$version"
    failed=1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'pin: FAILED: the manifest lists %s, which is not a helper source path\n' "$path"
    failed=1
  done < <(comm -13 <(ot_pin_source_paths | LC_ALL=C sort) \
    <(jq -r '.sources // {} | keys[]' "$manifest" 2> /dev/null | LC_ALL=C sort))
  while IFS= read -r path; do
    expected="$(jq -r --arg path "$path" '.sources[$path] // empty' "$manifest" 2> /dev/null || true)"
    if [ -z "$expected" ]; then
      printf 'pin: FAILED: the manifest records no id for %s\n' "$path"
      failed=1
      continue
    fi
    actual="$(ot_pin_source_id "$path" || true)"
    if [ "$actual" != "$expected" ]; then
      printf 'pin: FAILED: %s is %s at HEAD but the pin records %s; bump HelperIdentity.version and re-pin the helper\n' \
        "$path" "${actual:-missing}" "$expected"
      failed=1
    fi
  done < <(ot_pin_source_paths)
  [ "$failed" -eq 0 ]
}

ot_pin_check() {
  local root="$1" allow_missing="$2" version dir failed=0
  version="$(ot_helper_version)" || return 1
  dir="$(ot_pin_dir "$root" "$version")"
  if [ ! -e "$dir" ]; then
    printf 'pin: no pin yet for helper version %s\n' "$version"
    if [ "$allow_missing" = "1" ]; then
      return 0
    fi
    return 1
  fi
  ot_pin_check_sources "$dir/MANIFEST.json" || failed=1
  ot_pin_check_binary "$dir/OvertimeHelper" "$dir/MANIFEST.json" || failed=1
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  printf 'pin: current\n'
}

ot_pin_install() {
  local app="$1" pin_dir="$2"
  local target="$1/Contents/MacOS/OvertimeHelper" pinned="$2/OvertimeHelper"
  [ -f "$pinned" ] || ot_fail "no pinned helper at $pinned" || return 1
  [ -f "$target" ] || ot_fail "the built app has no helper at $target" || return 1
  cp "$pinned" "$target.pinned" || ot_fail "copying the pinned helper failed" || return 1
  mv -f "$target.pinned" "$target" || ot_fail "installing the pinned helper failed" || return 1
  cmp -s "$pinned" "$target" || ot_fail "the installed helper differs from the pin" || return 1
  printf 'pin: installed the helper from %s\n' "$pin_dir"
}

ot_pin_negative_control() {
  local out="$1" pin_dir="$2" copy="$1/selftest/OvertimeHelper"
  ot_pin_check_binary "$pin_dir/OvertimeHelper" "$pin_dir/MANIFEST.json" \
    || ot_fail "the fresh pin does not pass its own check" || return 1
  mkdir -p "$out/selftest"
  cp "$pin_dir/OvertimeHelper" "$copy" || ot_fail "copying the pin for the negative control failed" || return 1
  ot_tamper_last_byte "$copy"
  ! cmp -s "$pin_dir/OvertimeHelper" "$copy" || ot_fail "the negative-control copy is not tampered" || return 1
  if ot_pin_check_binary "$copy" "$pin_dir/MANIFEST.json" > "$out/logs/pin-selftest.log" 2>&1; then
    ot_fail "a helper with one flipped byte passed the pin check"
    return 1
  fi
  printf 'pin: negative control failed as expected\n'
}
