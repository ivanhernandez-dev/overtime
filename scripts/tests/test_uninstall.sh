#!/bin/bash

UNINSTALL="$REPO/scripts/uninstall.sh"
RELEASE_ID="io.github.ivanhernandez-dev.overtime"
LABEL="io.github.ivanhernandez-dev.overtime.helper"
STOPPED="Uninstall stopped. Overtime is still installed."
PROBLEMS="Uninstall finished with problems. See the lines above."
NOT_OWNED="Sleep is turned off system-wide (SleepDisabled). Overtime didn't set this, so it left it alone. To turn sleep back on, run: sudo pmset -a disablesleep 0"
LOGIN_ITEM="Still to do: Remove Overtime in System Settings > General > Login Items & Extensions."
CLEAR_FAILED="Couldn't turn system sleep back on. To turn sleep back on, run: sudo pmset -a disablesleep 0"
UNKNOWN="Sleep is turned off system-wide (SleepDisabled). Overtime can't tell who set this, so it left it alone. To turn sleep back on, run: sudo pmset -a disablesleep 0"
KEPT_ROOT="Kept Overtime's folders in /Library because an earlier step failed. Run the script again after fixing it."
SLEEP_UNREAD="Couldn't read the SleepDisabled setting. To check it, run: pmset -g"
FENCED="sudo launchctl pmset defaults security sfltool pkill killall osascript brew gh"
USER_ITEMS=(
  "Library/Application Support/Overtime"
  "Library/Logs/Overtime"
  "Library/Preferences/io.github.ivanhernandez-dev.overtime.plist"
  "Library/Caches/io.github.ivanhernandez-dev.overtime"
  "Library/HTTPStorages/io.github.ivanhernandez-dev.overtime"
  "Library/HTTPStorages/io.github.ivanhernandez-dev.overtime.binarycookies"
  "Library/Saved Application State/io.github.ivanhernandez-dev.overtime.savedState"
)
FOREIGN_ITEMS=(
  ".config/other-tool/config"
  ".local/bin/other-tool"
  "Library/LaunchAgents/local.other-tool.plist"
)

sandbox() {
  local tool
  new_sandbox
  for tool in sfltool pkill killall; do
    ln -s "$TESTS_DIR/shim.sh" "$T/bin/$tool"
  done
  OUTPUT="$T/output"
  STATUS=""
  APP_CALLS="$T/app.calls"
  RECORD="$T/root/Library/Application Support/Overtime/helper-state.json"
}

fake_app() {
  local bundle="$1" identifier="$2" code="$3" line
  shift 3
  mkdir -p "$bundle/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n<key>CFBundleIdentifier</key>\n<string>%s</string>\n</dict>\n</plist>\n' \
    "$identifier" > "$bundle/Contents/Info.plist"
  : > "$bundle/Contents/MacOS/lines"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$bundle/Contents/MacOS/lines"
  done
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$APP_CALLS"
    printf 'cat "%s"\n' "$bundle/Contents/MacOS/lines"
    printf 'exit %s\n' "$code"
  } > "$bundle/Contents/MacOS/Overtime"
  chmod +x "$bundle/Contents/MacOS/Overtime"
}

pmset_reads() {
  shim_allow_sub pmset -g 0 "System-wide power settings:
 SleepDisabled		$1
 DestroyFVKeyOnStandby		1
Currently in use:
 standby              1
 sleep                1
 displaysleep         10
"
}

helper_loaded() {
  if [ "$1" = "yes" ]; then
    shim_allow_sub launchctl print 0 "system/$LABEL = {"
  else
    shim_allow_sub launchctl print 113 "Could not find service \"$LABEL\" in domain for system"
  fi
}

allow_sudo() {
  : > "$SHIM_DIR/sudo.allow"
  shim_allow_sub launchctl bootout 0
  shim_allow_sub pmset -a 0
}

write_record() {
  mkdir -p "$(dirname "$RECORD")"
  printf '%s' "$1" > "$RECORD"
}

make_user_items() {
  local item
  for item in "${USER_ITEMS[@]}" "${FOREIGN_ITEMS[@]}"; do
    case "$item" in
      *.plist | *.binarycookies | */config | */other-tool)
        mkdir -p "$(dirname "$HOME/$item")"
        printf 'x\n' > "$HOME/$item"
        ;;
      *)
        mkdir -p "$HOME/$item"
        printf 'x\n' > "$HOME/$item/file"
        ;;
    esac
  done
  mkdir -p "$T/root/Library/Logs/Overtime"
  printf 'x\n' > "$T/root/Library/Logs/Overtime/helper.log"
  mkdir -p "$T/root/Library/Application Support/Overtime"
}

run_uninstall() {
  /bin/bash "$UNINSTALL" "$@" > "$OUTPUT" 2>&1
  STATUS=$?
}

status_is() {
  [ "$STATUS" -eq "$1" ] || { printf 'status %s\n' "$STATUS"; cat "$OUTPUT"; return 1; }
}

output_has() {
  grep -qxF -- "$1" "$OUTPUT" || { cat "$OUTPUT"; return 1; }
}

output_lacks() {
  ! grep -qF -- "$1" "$OUTPUT" || { cat "$OUTPUT"; return 1; }
}

app_calls_are() {
  [ "$(cat "$APP_CALLS" 2> /dev/null)" = "$1" ] || { printf 'app calls: %s\n' "$(cat "$APP_CALLS" 2> /dev/null)"; return 1; }
}

app_never_ran() {
  [ ! -e "$APP_CALLS" ]
}

nothing_fenced_called() {
  no_shim_calls $FENCED
}

sudo_called() {
  shim_calls sudo | grep -qxF -- "$1" || { shim_calls sudo; return 1; }
}

no_pmset_write() {
  ! shim_calls pmset | grep -q '^-a' && ! shim_calls sudo | grep -q '^pmset'
}

all_user_items_remain() {
  local item
  for item in "${USER_ITEMS[@]}"; do
    [ -e "$HOME/$item" ] || { printf 'gone: %s\n' "$item"; return 1; }
  done
}

all_user_items_gone() {
  local item
  for item in "${USER_ITEMS[@]}"; do
    [ ! -e "$HOME/$item" ] || { printf 'remains: %s\n' "$item"; return 1; }
  done
}

foreign_items_remain() {
  local item
  for item in "${FOREIGN_ITEMS[@]}"; do
    [ -f "$HOME/$item" ] || { printf 'gone: %s\n' "$item"; return 1; }
  done
}

root_folders_gone() {
  [ ! -e "$T/root/Library/Application Support/Overtime" ] && [ ! -e "$T/root/Library/Logs/Overtime" ]
}

root_folders_remain() {
  [ -d "$T/root/Library/Application Support/Overtime" ] && [ -f "$T/root/Library/Logs/Overtime/helper.log" ]
}

every_action_is_would() {
  local line count=0
  while IFS= read -r line; do
    [ "$line" = "$LOGIN_ITEM" ] && continue
    case "$line" in
      "would: "*) count=$((count + 1)) ;;
      *)
        printf 'not a would line: %s\n' "$line"
        return 1
        ;;
    esac
  done < "$OUTPUT"
  [ "$count" -gt 0 ]
}

no_dry_run_writes() {
  no_shim_calls sudo && ! shim_calls launchctl | grep -q '^bootout' && ! shim_calls pmset | grep -q '^-a'
}

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 0 "Stop keeping the Mac awake: done" "Remove unplug protection: skipped. Not installed." "Overtime is uninstalled."
run_uninstall --app "$APP"
check "app present: exits 0" status_is 0
check "app present: the bundle's binary got --uninstall" app_calls_are "--uninstall"
check "app present: the three headless lines pass through in order" \
  test "$(head -3 "$OUTPUT")" = "Stop keeping the Mac awake: done
Remove unplug protection: skipped. Not installed.
Overtime is uninstalled."
check "app present: the bundle is removed and said so" eval '[ ! -e "$APP" ] && output_has "Removed Overtime.app."'
check "app present: no sudo, launchctl, pmset, defaults, security, sfltool, pkill, killall, osascript, brew or gh" \
  nothing_fenced_called

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 0 "Overtime is uninstalled."
run_uninstall --purge --app "$APP/"
check "app present with --purge: the binary got --uninstall --purge and the bundle is gone" \
  eval 'status_is 0 && app_calls_are "--uninstall --purge" && [ ! -e "$APP" ]'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "com.example.other" 0 "Overtime is uninstalled."
run_uninstall --app "$APP"
check "another identifier: refused with exit 1, the binary never ran and the bundle remains" \
  eval 'status_is 1 && app_never_ran && [ -x "$APP/Contents/MacOS/Overtime" ]'

sandbox
TARGET="$T/apps/Real.app"
fake_app "$TARGET" "$RELEASE_ID" 0 "Overtime is uninstalled."
ln -s "$TARGET" "$T/apps/Overtime.app"
run_uninstall --app "$T/apps/Overtime.app"
check "a symlinked bundle: refused with exit 1, the link and its target remain" \
  eval 'status_is 1 && app_never_ran && [ -L "$T/apps/Overtime.app" ] && [ -x "$TARGET/Contents/MacOS/Overtime" ]'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 1 "Remove unplug protection: failed. macOS didn't remove the helper." "$STOPPED"
run_uninstall --app "$APP"
check "a stopped run keeps the bundle and exits 1" \
  eval 'status_is 1 && [ -d "$APP" ] && output_lacks "Removed Overtime.app." && output_has "$STOPPED"'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 1 "Remove Overtime from your login items: failed. Couldn't remove the login item." "$PROBLEMS"
run_uninstall --app "$APP"
check "a run with problems removes the bundle and exits 1" \
  eval 'status_is 1 && [ ! -e "$APP" ] && output_has "Removed Overtime.app."'

check "a run with problems and no unknown owner never reads or writes SleepDisabled" nothing_fenced_called

UNKNOWN_ROW="Turn system sleep back on if unplug protection turned it off: skipped. Overtime can't tell who turned sleep off, so it left the setting alone."
app_says_unknown() {
  APP="$T/apps/Overtime.app"
  fake_app "$APP" "$RELEASE_ID" 1 "$UNKNOWN_ROW" "$UNKNOWN" "$PROBLEMS"
}

sandbox
app_says_unknown
pmset_reads 1
allow_sudo
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app "$APP"
check "an unknown owner from the app is resolved by the script's own record read: an owned value is cleared" \
  eval 'status_is 1 && [ ! -e "$APP" ] && sudo_called "pmset -a disablesleep 0" && output_has "Turned system sleep back on."'
check "the resolution runs after the bundle is removed" \
  eval '[ "$(grep -n "Removed Overtime.app." "$OUTPUT" | cut -d: -f1)" -lt "$(grep -n "Turned system sleep back on." "$OUTPUT" | cut -d: -f1)" ]'

sandbox
app_says_unknown
pmset_reads 1
allow_sudo
write_record '{"at":1,"owns":false,"prior":true}'
run_uninstall --app "$APP"
check "an unknown owner from the app with a record that says not owned: no pmset write and the not-owned line" \
  eval 'status_is 1 && [ ! -e "$APP" ] && no_pmset_write && output_has "$NOT_OWNED"'

sandbox
app_says_unknown
pmset_reads 1
: > "$SHIM_DIR/sudo.validate-only"
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app "$APP"
check "an unknown owner the script can't resolve either: no pmset write and the unknown line once" \
  eval 'status_is 1 && [ ! -e "$APP" ] && no_pmset_write && [ "$(grep -cxF -- "$UNKNOWN" "$OUTPUT")" = "1" ]'

sandbox
app_says_unknown
pmset_reads 0
allow_sudo
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app "$APP"
check "an unknown owner from the app with SleepDisabled already 0: no sudo and no pmset write" \
  eval 'status_is 1 && [ ! -e "$APP" ] && no_shim_calls sudo && no_pmset_write'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 75 "Asked the running Overtime to quit." "Overtime is still running. Quit it, then run Overtime --uninstall again."
run_uninstall --app "$APP"
check "exit 75 passes through and keeps the bundle" eval 'status_is 75 && [ -d "$APP" ]'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 64 "Run Overtime --uninstall as the user who installed Overtime, not with sudo."
make_user_items
run_uninstall --purge --app "$APP"
check "an app that refuses with exit 64 keeps the bundle, says so and exits 1" \
  eval 'status_is 1 && [ -x "$APP/Contents/MacOS/Overtime" ] && output_lacks "Removed Overtime.app." && output_has "Overtime --uninstall ended with exit 64. Overtime.app was kept."'
check "an app that refuses with exit 64 leaves every user item and /Library folder and calls nothing fenced" \
  eval 'all_user_items_remain && root_folders_remain && nothing_fenced_called'

sandbox
APP="$T/apps/Overtime.app"
fake_app "$APP" "$RELEASE_ID" 0 "Overtime is uninstalled."
helper_loaded no
pmset_reads 0
run_uninstall --app-absent --app "$APP"
check "--app-absent never runs or removes a present bundle" eval 'status_is 0 && app_never_ran && [ -d "$APP" ]'

sandbox
make_user_items
helper_loaded yes
pmset_reads 1
allow_sudo
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app "$T/apps/Overtime.app"
check "app absent: exits 0" status_is 0
check "app absent: the loaded helper is booted out with sudo" sudo_called "launchctl bootout system/$LABEL"
check "app absent: an owned SleepDisabled 1 is cleared with sudo" sudo_called "pmset -a disablesleep 0"
check "app absent: the steps and the Login Items manual step are printed" \
  eval 'output_has "Stopped the helper." && output_has "Turned system sleep back on." && output_has "$LOGIN_ITEM"'
check "app absent without --purge: every user item remains" all_user_items_remain
check "app absent: no defaults, security, sfltool, pkill, killall, osascript, brew or gh" \
  no_shim_calls defaults security sfltool pkill killall osascript brew gh

sandbox
helper_loaded yes
pmset_reads 1
allow_sudo
write_record '{"at":1,"owns":false,"prior":true}'
run_uninstall --app-absent
check "a record with owns false: no pmset write and the not-owned line" \
  eval 'status_is 0 && no_pmset_write && output_has "$NOT_OWNED"'

sandbox
helper_loaded yes
pmset_reads 1
allow_sudo
write_record 'not json {'
run_uninstall --app-absent
check "an unreadable record is unknown: no pmset write, the command line and exit 1" \
  eval 'status_is 1 && no_pmset_write && output_has "$UNKNOWN" && output_lacks "$NOT_OWNED" && output_has "$PROBLEMS"'

sandbox
helper_loaded yes
pmset_reads 1
allow_sudo
write_record '{"at":1,"prior":false}'
run_uninstall --app-absent
check "a record with no owns value is unknown: no pmset write and exit 1" \
  eval 'status_is 1 && no_pmset_write && output_has "$UNKNOWN"'

sandbox
helper_loaded yes
pmset_reads 1
allow_sudo
run_uninstall --app-absent
check "no record: not owned, no pmset write and the not-owned line" \
  eval 'status_is 0 && no_pmset_write && output_has "$NOT_OWNED"'

sandbox
helper_loaded no
pmset_reads 1
run_uninstall --app-absent
check "no helper folder at all: not owned without asking for sudo" \
  eval 'status_is 0 && no_shim_calls sudo && no_pmset_write && output_has "$NOT_OWNED"'

sandbox
helper_loaded no
pmset_reads 1
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app-absent
check "a refused or failed sudo is unknown, not not-owned: no pmset write, the command line and exit 1" \
  eval 'status_is 1 && no_pmset_write && output_has "$UNKNOWN" && output_lacks "$NOT_OWNED" && output_has "$PROBLEMS"'
check "a refused sudo is asked once to validate, before any record read" \
  eval '[ "$(shim_calls sudo)" = "-v" ]'

sandbox
helper_loaded no
pmset_reads 1
: > "$SHIM_DIR/sudo.validate-only"
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app-absent
check "a sudo that fails after sudo -v is unknown, not not-owned: no pmset write, the command line and exit 1" \
  eval 'status_is 1 && no_pmset_write && output_has "$UNKNOWN" && output_lacks "$NOT_OWNED" && output_has "$PROBLEMS"'
check "a sudo that fails after sudo -v read the record through one more sudo call" \
  eval '[ "$(shim_calls sudo | grep -cv "^-v$")" = "1" ]'

sandbox
make_user_items
helper_loaded no
pmset_reads 1
: > "$SHIM_DIR/sudo.validate-only"
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --purge --app-absent
check "--purge with a sudo that fails after sudo -v keeps the record and both /Library folders" \
  eval 'status_is 1 && [ -f "$RECORD" ] && root_folders_remain && output_has "$KEPT_ROOT" && no_pmset_write'

sandbox
helper_loaded no
pmset_reads 1
: > "$SHIM_DIR/sudo.validate-only"
mkdir -p "$(dirname "$RECORD")"
run_uninstall --app-absent
check "a helper folder with a sudo that fails after sudo -v is unknown even with no record" \
  eval 'status_is 1 && no_pmset_write && output_has "$UNKNOWN" && output_lacks "$NOT_OWNED"'

sandbox
make_user_items
write_record '{"at":1,"owns":true,"prior":false}'
helper_loaded yes
pmset_reads 1
allow_sudo
shim_allow_sub launchctl bootout 5
run_uninstall --purge --app-absent
check "--purge after a failed bootout keeps the record and both /Library folders and exits 1" \
  eval 'status_is 1 && [ -f "$RECORD" ] && root_folders_remain && output_has "$KEPT_ROOT" && output_has "$PROBLEMS"'
check "--purge after a failed bootout still removes the user items" all_user_items_gone

sandbox
make_user_items
write_record '{"at":1,"owns":true,"prior":false}'
helper_loaded yes
pmset_reads 1
allow_sudo
shim_allow_sub pmset -a 1
run_uninstall --purge --app-absent
check "--purge after a failed pmset write keeps the record and both /Library folders and exits 1" \
  eval 'status_is 1 && [ -f "$RECORD" ] && root_folders_remain && output_has "$KEPT_ROOT" && output_has "$CLEAR_FAILED"'

sandbox
make_user_items
write_record 'not json {'
helper_loaded no
pmset_reads 1
allow_sudo
run_uninstall --purge --app-absent
check "--purge with an unknown owner keeps the record and both /Library folders" \
  eval 'status_is 1 && [ -f "$RECORD" ] && root_folders_remain && output_has "$KEPT_ROOT" && no_pmset_write'

sandbox
make_user_items
write_record '{"at":1,"owns":false,"prior":true}'
helper_loaded yes
pmset_reads 1
allow_sudo
run_uninstall --purge --app-absent
check "--purge with a not-owned value removes the /Library folders and leaves the value alone" \
  eval 'status_is 0 && root_folders_gone && no_pmset_write && output_has "$NOT_OWNED"'

sandbox
make_user_items
helper_loaded no
allow_sudo
run_uninstall --purge --app-absent
check "an unreadable SleepDisabled keeps the /Library folders and exits 1" \
  eval 'status_is 1 && root_folders_remain && output_has "$SLEEP_UNREAD" && output_has "$KEPT_ROOT"'

sandbox
helper_loaded no
pmset_reads 0
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app-absent
check "helper not loaded and SleepDisabled 0: no bootout, no sudo, no pmset write" \
  eval 'status_is 0 && no_shim_calls sudo && ! shim_calls launchctl | grep -q "^bootout" && no_pmset_write && output_has "$LOGIN_ITEM"'

sandbox
helper_loaded yes
pmset_reads 1
allow_sudo
shim_allow_sub pmset -a 1
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --app-absent
check "a failed pmset write exits 1 with the command to run" \
  eval 'status_is 1 && output_has "$CLEAR_FAILED" && output_has "$PROBLEMS"'

sandbox
make_user_items
helper_loaded no
pmset_reads 0
allow_sudo
run_uninstall --purge --app-absent
check "--purge with the app absent: exits 0 and says so" eval 'status_is 0 && output_has "Removed settings, state and logs."'
check "--purge: the seven user items are gone" all_user_items_gone
check "--purge: both /Library folders under the root are gone through one sudo rm" \
  eval 'root_folders_gone && [ "$(shim_calls sudo | grep -c "^rm -rf -- ")" = "1" ]'
check "--purge: the files of other apps remain" foreign_items_remain
check "--purge: no defaults or security call" no_shim_calls defaults security

sandbox
mkdir -p "$T/root/Applications"
fake_app "$T/root/Applications/Overtime.app" "$RELEASE_ID" 0 "Overtime is uninstalled."
run_uninstall --dry-run --purge
check "--dry-run, app present at the default path under the root: only would lines" \
  eval 'status_is 0 && every_action_is_would && output_has "would: run $T/root/Applications/Overtime.app/Contents/MacOS/Overtime --uninstall --purge"'
check "--dry-run, app present: the binary never ran and the bundle remains" \
  eval 'app_never_ran && [ -x "$T/root/Applications/Overtime.app/Contents/MacOS/Overtime" ] && nothing_fenced_called'

sandbox
make_user_items
helper_loaded yes
pmset_reads 1
write_record '{"at":1,"owns":true,"prior":false}'
run_uninstall --dry-run --purge --app-absent
check "--dry-run, app absent with --purge: every printed action starts with would:" \
  eval 'status_is 0 && every_action_is_would && output_has "would: sudo launchctl bootout system/$LABEL"'
check "--dry-run, app absent: every item, both root folders and the record remain" \
  eval 'all_user_items_remain && root_folders_remain && [ -f "$RECORD" ] && foreign_items_remain'
check "--dry-run, app absent: no sudo, no bootout and no pmset write" no_dry_run_writes

sandbox
run_uninstall --frobnicate
check "an unknown argument exits 64" status_is 64
run_uninstall --app
check "--app without a value exits 64" status_is 64

sandbox
make_user_items
allow_sudo
helper_loaded yes
pmset_reads 1
env -u HOME /bin/bash "$UNINSTALL" --purge --app-absent > "$OUTPUT" 2>&1
STATUS=$?
check "an unset HOME is refused with exit 64 before any step" \
  eval 'status_is 64 && no_shim_calls launchctl pmset && all_user_items_remain && root_folders_remain'

for bad_home in "//" "/." "/./" "///./" "/private/.." "/private/var/../.." "/.." "private/me"; do
  sandbox
  make_user_items
  helper_loaded yes
  pmset_reads 1
  allow_sudo
  write_record '{"at":1,"owns":true,"prior":false}'
  HOME="$bad_home" /bin/bash "$UNINSTALL" --dry-run --purge --app-absent > "$OUTPUT" 2>&1
  STATUS=$?
  check "a HOME of '$bad_home' is refused with exit 64 before any step" \
    eval 'status_is 64 && nothing_fenced_called && output_lacks "would:" && [ -f "$RECORD" ] && root_folders_remain'
done

sandbox
make_user_items
helper_loaded yes
pmset_reads 1
allow_sudo
write_record '{"at":1,"owns":true,"prior":false}'
HOME="$T/root" /bin/bash "$UNINSTALL" --dry-run --purge --app-absent > "$OUTPUT" 2>&1
STATUS=$?
check "a HOME whose user items are the /Library folders is refused with exit 64 before any step" \
  eval 'status_is 64 && nothing_fenced_called && output_lacks "would:" && [ -f "$RECORD" ] && root_folders_remain'

sandbox
make_user_items
helper_loaded no
pmset_reads 0
allow_sudo
HOME="$T//./home/" /bin/bash "$UNINSTALL" --purge --app-absent > "$OUTPUT" 2>&1
STATUS=$?
check "a HOME with extra slashes and dot components is normalised and its user items are removed" \
  eval 'status_is 0 && all_user_items_gone && foreign_items_remain && root_folders_gone'

sandbox
OVERTIME_UNINSTALL_ROOT=/ run_uninstall --app-absent
check "a test root of / exits 64 before any step" eval 'status_is 64 && nothing_fenced_called'
OVERTIME_UNINSTALL_ROOT="$T/no-such-root" run_uninstall --app-absent
check "a test root that is not a folder exits 64 before any step" eval 'status_is 64 && nothing_fenced_called'

check "uninstall.sh parses under /bin/bash" /bin/bash -n "$UNINSTALL"
