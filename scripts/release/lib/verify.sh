#!/bin/bash
set -euo pipefail

OT_APP_ENTITLEMENTS_JSON='{"com.apple.security.cs.disable-library-validation":true,"com.apple.security.personal-information.location":true}'

ot_code_items() {
  local app="$1"
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  printf '%s\n' "$app" "$framework" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" \
    "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$app/Contents/MacOS/overtime-sentinel" "$app/Contents/MacOS/OvertimeHelper"
}

ot_item_name() {
  local app="$1" item="$2"
  if [ "$item" = "$app" ]; then
    printf '%s\n' "$(basename "$app")"
  else
    printf '%s\n' "${item#"$app"/}"
  fi
}

ot_verify_result() {
  local name="$1" detail="$2"
  if [ -z "$detail" ]; then
    printf 'verify: %s ok\n' "$name"
    return 0
  fi
  printf 'verify: %s FAILED:%s\n' "$name" "$detail"
  return 1
}

ot_entitlements_xml() {
  codesign -d --entitlements - --xml "$1" 2> /dev/null || true
}

ot_check_signatures() {
  local app="$1" item detail=""
  while IFS= read -r item; do
    if [ ! -e "$item" ]; then
      detail="$detail missing $(ot_item_name "$app" "$item");"
    elif ! codesign --verify --strict "$item" > /dev/null 2>&1; then
      detail="$detail $(ot_item_name "$app" "$item");"
    fi
  done < <(ot_code_items "$app")
  ot_verify_result signatures "$detail"
}

ot_check_designated_requirement() {
  local app="$1" mode="$2" actual
  if [ "$mode" = "dry-run" ]; then
    printf 'verify: designated requirement skipped: ad-hoc\n'
    return 0
  fi
  actual="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
  if [ "$actual" = "$APP_DESIGNATED_REQUIREMENT" ]; then
    ot_verify_result "designated requirement" ""
  else
    ot_verify_result "designated requirement" " got '$actual'"
  fi
}

ot_check_runtime_flags() {
  local app="$1" item info detail=""
  local pattern='flags=0x[0-9a-fA-F]+\([^)]*runtime[^)]*\)'
  while IFS= read -r item; do
    info="$(codesign -dvvv "$item" 2>&1 || true)"
    if [[ ! "$info" =~ $pattern ]]; then
      detail="$detail $(ot_item_name "$app" "$item");"
    fi
  done < <(ot_code_items "$app")
  ot_verify_result "runtime flags" "$detail"
}

ot_check_app_entitlements() {
  local app="$1" xml json
  xml="$(ot_entitlements_xml "$app")"
  if [ -z "$xml" ]; then
    ot_verify_result "app entitlements" " no entitlements read from the app"
    return 1
  fi
  json="$(printf '%s\n' "$xml" | plutil -convert json -o - - 2> /dev/null | jq -S -c . 2> /dev/null || true)"
  if [ "$json" = "$OT_APP_ENTITLEMENTS_JSON" ]; then
    ot_verify_result "app entitlements" ""
  else
    ot_verify_result "app entitlements" " got ${json:-unreadable}"
  fi
}

ot_check_no_get_task_allow() {
  local app="$1" item detail="" xml
  if [ -z "$(ot_entitlements_xml "$app")" ]; then
    ot_verify_result "no get-task-allow" " the app's entitlements read is empty, so the instrument is broken"
    return 1
  fi
  for item in "$app" "$app/Contents/MacOS/overtime-sentinel" "$app/Contents/MacOS/OvertimeHelper"; do
    xml="$(ot_entitlements_xml "$item")"
    case "$xml" in
      *com.apple.security.get-task-allow*) detail="$detail $(ot_item_name "$app" "$item");" ;;
    esac
  done
  ot_verify_result "no get-task-allow" "$detail"
}

ot_check_helper_entitlements() {
  local app="$1" helper_bytes app_bytes
  app_bytes="$(ot_entitlements_xml "$app" | wc -c | tr -d ' ')"
  helper_bytes="$(ot_entitlements_xml "$app/Contents/MacOS/OvertimeHelper" | wc -c | tr -d ' ')"
  if [ "$app_bytes" -eq 0 ]; then
    ot_verify_result "helper entitlements" " the app's entitlements read is empty, so the instrument is broken"
  elif [ "$helper_bytes" -ne 0 ]; then
    ot_verify_result "helper entitlements" " the helper carries $helper_bytes bytes of entitlements"
  else
    ot_verify_result "helper entitlements" ""
  fi
}

ot_macho_list() {
  local app="$1" list="$2" file
  : > "$list"
  while IFS= read -r file; do
    if lipo -archs "$file" > /dev/null 2>&1; then
      printf '%s\n' "$file" >> "$list"
    fi
  done < <(find "$app" -type f)
}

ot_check_architectures() {
  local app="$1" list file archs detail=""
  list="$(mktemp "${TMPDIR:-/tmp}/overtime-macho.XXXXXX")"
  ot_macho_list "$app" "$list"
  if [ ! -s "$list" ]; then
    detail=" no Mach-O found"
  fi
  while IFS= read -r file; do
    archs="$(lipo -archs "$file" 2> /dev/null || true)"
    if [ "$archs" != "arm64" ]; then
      detail="$detail $(ot_item_name "$app" "$file") ($archs);"
    fi
  done < "$list"
  rm -f "${list:?}"
  ot_verify_result architectures "$detail"
}

ot_check_minimum_os() {
  local app="$1" list file minos value major minor detail=""
  list="$(mktemp "${TMPDIR:-/tmp}/overtime-macho.XXXXXX")"
  ot_macho_list "$app" "$list"
  if [ ! -s "$list" ]; then
    detail=" no Mach-O found"
  fi
  while IFS= read -r file; do
    minos="$(vtool -show-build "$file" 2> /dev/null | awk '$1 == "minos" { print $2 }' || true)"
    if [ -z "$minos" ]; then
      detail="$detail $(ot_item_name "$app" "$file") (no minos);"
      continue
    fi
    for value in $minos; do
      major="${value%%.*}"
      minor="${value#*.}"
      minor="${minor%%.*}"
      [ "$minor" != "$value" ] || minor=0
      if [ "$((major * 100 + minor))" -gt 1400 ]; then
        detail="$detail $(ot_item_name "$app" "$file") (minos $value);"
      fi
    done
  done < "$list"
  rm -f "${list:?}"
  ot_verify_result "minimum os" "$detail"
}

ot_plist_expect() {
  local plist="$1" key="$2" type="$3" expected="$4" actual_type actual
  actual_type="$(plutil -type "$key" "$plist" 2> /dev/null || true)"
  actual="$(plutil -extract "$key" raw -o - "$plist" 2> /dev/null || true)"
  if [ "$actual_type" != "$type" ] || [ "$actual" != "$expected" ]; then
    printf ' %s is %s %s, expected %s %s;' "$key" "${actual_type:-missing}" "$actual" "$type" "$expected"
  fi
}

ot_check_info_plist() {
  local app="$1" version="$2" build="$3" key="$4"
  local plist="$app/Contents/Info.plist" detail=""
  detail="$detail$(ot_plist_expect "$plist" CFBundleIdentifier string "$APP_BUNDLE_ID")"
  detail="$detail$(ot_plist_expect "$plist" CFBundleShortVersionString string "$version")"
  detail="$detail$(ot_plist_expect "$plist" CFBundleVersion string "$build")"
  detail="$detail$(ot_plist_expect "$plist" LSMinimumSystemVersion string 14.0)"
  detail="$detail$(ot_plist_expect "$plist" LSUIElement bool true)"
  detail="$detail$(ot_plist_expect "$plist" SUFeedURL string "$FEED_URL")"
  detail="$detail$(ot_plist_expect "$plist" SUPublicEDKey string "$key")"
  detail="$detail$(ot_plist_expect "$plist" SUEnableAutomaticChecks bool true)"
  detail="$detail$(ot_plist_expect "$plist" SUScheduledCheckInterval integer 86400)"
  detail="$detail$(ot_plist_expect "$plist" SUAutomaticallyUpdate bool false)"
  detail="$detail$(ot_plist_expect "$plist" SUEnableSystemProfiling bool false)"
  detail="$detail$(ot_plist_expect "$plist" SUVerifyUpdateBeforeExtraction bool true)"
  detail="$detail$(ot_plist_expect "$plist" SURequireSignedFeed bool true)"
  ot_verify_result "info plist" "$detail"
}

ot_check_resources() {
  local app="$1" resources="$1/Contents/Resources" detail="" marker line file
  marker="The Sparkle license, copied verbatim from the Sparkle $SPARKLE_VERSION distribution, follows."
  for file in NOTICE LICENSE; do
    if [ ! -f "$resources/$file" ]; then
      detail="$detail missing $file;"
    elif ! cmp -s "$resources/$file" "$REPO/$file"; then
      detail="$detail $file differs from the repository;"
    fi
  done
  if [ ! -f "$resources/uninstall.sh" ]; then
    detail="$detail missing uninstall.sh;"
  elif ! cmp -s "$resources/uninstall.sh" "$REPO/scripts/uninstall.sh"; then
    detail="$detail uninstall.sh differs from the repository;"
  elif [ ! -x "$resources/uninstall.sh" ]; then
    detail="$detail uninstall.sh is not executable;"
  fi
  if [ -f "$resources/NOTICE" ]; then
    line="$(grep -n -x -F "$marker" "$resources/NOTICE" | head -1 | cut -d: -f1 || true)"
    if [ -z "$line" ]; then
      detail="$detail NOTICE lacks the Sparkle marker line;"
    elif [ -n "$(sed -n "$((line + 1))p" "$resources/NOTICE")" ]; then
      detail="$detail NOTICE lacks the blank line after the marker;"
    elif ! tail -n "+$((line + 2))" "$resources/NOTICE" | cmp -s - "$OT_SPARKLE_ARTIFACT/LICENSE"; then
      detail="$detail the NOTICE tail differs from Sparkle's LICENSE;"
    fi
  fi
  ot_verify_result resources "$detail"
}

ot_check_helper_pin() {
  local app="$1" manifest="$2" output
  if output="$(ot_pin_check_binary "$app/Contents/MacOS/OvertimeHelper" "$manifest" 2>&1)"; then
    ot_verify_result "helper pin" ""
  else
    ot_verify_result "helper pin" " $(printf '%s\n' "$output" | sed 's/^pin: FAILED: //' | tr '\n' ';')"
  fi
}

ot_check_helper_requirement() {
  local app="$1" actual
  actual="$(codesign -d -r- "$app/Contents/MacOS/OvertimeHelper" 2>&1 | sed -n 's/^designated => //p')"
  if [ -n "$actual" ] && [ "$actual" = "$HELPER_DESIGNATED_REQUIREMENT" ]; then
    ot_verify_result "helper requirement" ""
  else
    ot_verify_result "helper requirement" " got '$actual'"
  fi
}

ot_verify_all() {
  local app="$1" mode="$2" version="$3" build="$4" key="$5" out="$6" manifest="$7" failed=0
  ot_check_signatures "$app" || failed=1
  ot_check_designated_requirement "$app" "$mode" || failed=1
  ot_check_runtime_flags "$app" || failed=1
  ot_check_app_entitlements "$app" || failed=1
  ot_check_no_get_task_allow "$app" || failed=1
  ot_check_helper_entitlements "$app" || failed=1
  ot_check_architectures "$app" || failed=1
  ot_check_minimum_os "$app" || failed=1
  ot_check_info_plist "$app" "$version" "$build" "$key" || failed=1
  ot_check_resources "$app" "$out" || failed=1
  ot_check_helper_pin "$app" "$manifest" || failed=1
  if [ "$mode" = "dry-run" ]; then
    printf 'verify: helper requirement skipped: ad-hoc\n'
  else
    ot_check_helper_requirement "$app" || failed=1
  fi
  [ "$failed" -eq 0 ] || ot_fail "verify found problems"
}
