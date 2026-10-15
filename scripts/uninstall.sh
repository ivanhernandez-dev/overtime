#!/bin/bash
set -euo pipefail

if [ "${OVERTIME_SCRIPT_TESTS:-}" != "1" ]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
fi

APP_IDENTIFIER="io.github.ivanhernandez-dev.overtime"
HELPER_LABEL="io.github.ivanhernandez-dev.overtime.helper"
RECORD_FILE="helper-state.json"
USER_ITEMS=(
  "Library/Application Support/Overtime"
  "Library/Logs/Overtime"
  "Library/Preferences/io.github.ivanhernandez-dev.overtime.plist"
  "Library/Caches/io.github.ivanhernandez-dev.overtime"
  "Library/HTTPStorages/io.github.ivanhernandez-dev.overtime"
  "Library/HTTPStorages/io.github.ivanhernandez-dev.overtime.binarycookies"
  "Library/Saved Application State/io.github.ivanhernandez-dev.overtime.savedState"
)
ROOT_ITEMS=(
  "Library/Application Support/Overtime"
  "Library/Logs/Overtime"
)
STOPPED_LINE="Uninstall stopped. Overtime is still installed."
PROBLEMS_LINE="Uninstall finished with problems. See the lines above."
NOT_OWNED_LINE="Sleep is turned off system-wide (SleepDisabled). Overtime didn't set this, so it left it alone. To turn sleep back on, run: sudo pmset -a disablesleep 0"
UNKNOWN_OWNER_LINE="Sleep is turned off system-wide (SleepDisabled). Overtime can't tell who set this, so it left it alone. To turn sleep back on, run: sudo pmset -a disablesleep 0"
SLEEP_UNREAD_LINE="Couldn't read the SleepDisabled setting. To check it, run: pmset -g"
KEPT_ROOT_LINE="Kept Overtime's folders in /Library because an earlier step failed. Run the script again after fixing it."
LOGIN_ITEM_LINE="Still to do: Remove Overtime in System Settings > General > Login Items & Extensions."

usage() {
  printf 'usage: uninstall.sh [--purge] [--app PATH] [--app-absent] [--dry-run]\n' >&2
  exit 64
}

refuse() {
  printf 'uninstall: %s\n' "$1" >&2
  exit "$2"
}

ROOT_PREFIX=""
if [ "${OVERTIME_SCRIPT_TESTS:-}" = "1" ]; then ROOT_PREFIX="${OVERTIME_UNINSTALL_ROOT:-}"; fi
if [ "${OVERTIME_SCRIPT_TESTS:-}" = "1" ]; then
  [ -n "$ROOT_PREFIX" ] && [ -d "$ROOT_PREFIX" ] && [ ! -L "$ROOT_PREFIX" ] || refuse "the test root is not a folder" 64
  [ "$(cd "$ROOT_PREFIX" && pwd -P)" != "/" ] || refuse "the test root must not be /" 64
  ROOT_PREFIX="$(cd "$ROOT_PREFIX" && pwd)"
fi

[ -n "${HOME:-}" ] || refuse "HOME is not set" 64
case "$HOME" in
  /*) ;;
  *) refuse "HOME must be an absolute path" 64 ;;
esac
USER_HOME=""
rest="$HOME"
while [ -n "$rest" ]; do
  part="${rest%%/*}"
  if [ "$part" = "$rest" ]; then
    rest=""
  else
    rest="${rest#*/}"
  fi
  case "$part" in
    "" | .) ;;
    ..) refuse "HOME must not contain .." 64 ;;
    *) USER_HOME="$USER_HOME/$part" ;;
  esac
done
[ -n "$USER_HOME" ] || refuse "HOME must not be /" 64
for item in "${USER_ITEMS[@]}"; do
  for root_item in "${ROOT_ITEMS[@]}"; do
    [ "$USER_HOME/$item" != "$ROOT_PREFIX/$root_item" ] || refuse "HOME must not be the folder that holds /Library" 64
  done
done

PURGE=0
APP_ABSENT=0
DRY_RUN=0
APP="$ROOT_PREFIX/Applications/Overtime.app"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)
      PURGE=1
      shift
      ;;
    --app-absent)
      APP_ABSENT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --app)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      APP="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

while [ "${#APP}" -gt 1 ] && [ "${APP%/}" != "$APP" ]; do
  APP="${APP%/}"
done
case "$APP" in
  *.app) ;;
  *) refuse "--app must name an .app bundle" 64 ;;
esac

say() {
  printf '%s\n' "$1"
}

would() {
  printf 'would: %s\n' "$1"
}

exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

remove_bundle() {
  if rm -rf -- "${APP:?}"; then
    say "Removed Overtime.app."
    return 0
  fi
  say "Couldn't remove Overtime.app. Drag Overtime to the Trash."
  return 1
}

uninstall_present() {
  local binary="$APP/Contents/MacOS/Overtime" identifier summary code last rest unknown
  if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    refuse "$APP is not an app folder (a symbolic link or a file). Nothing was removed." 1
  fi
  identifier="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2> /dev/null || true)"
  if [ "$identifier" != "$APP_IDENTIFIER" ]; then
    refuse "$APP is not Overtime (bundle identifier '${identifier}'). Nothing was removed." 1
  fi
  if [ -L "$binary" ] || [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
    refuse "$APP has no Overtime executable. Nothing was removed." 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$PURGE" -eq 1 ]; then
      would "run $binary --uninstall --purge"
    else
      would "run $binary --uninstall"
    fi
    would "remove $APP"
    exit 0
  fi
  local run=("$binary" --uninstall)
  if [ "$PURGE" -eq 1 ]; then
    run+=(--purge)
  fi
  exec 3>&1
  summary="$(
    {
      if "${run[@]}"; then
        printf '%s\n' 0
      else
        printf '%s\n' "$?"
      fi
    } | {
      held=""
      have=0
      final=""
      unknown=0
      while IFS= read -r line; do
        if [ "$have" -eq 1 ]; then
          printf '%s\n' "$held" >&3
          final="$held"
        fi
        if [ "$line" = "$UNKNOWN_OWNER_LINE" ]; then
          unknown=1
        fi
        held="$line"
        have=1
      done
      printf '%s\n%s\n%s\n' "$unknown" "$final" "$held"
    }
  )"
  exec 3>&-
  code="${summary##*$'\n'}"
  rest="${summary%$'\n'*}"
  last="${rest#*$'\n'}"
  unknown="${rest%%$'\n'*}"
  case "$code" in
    0)
      remove_bundle || exit 1
      exit 0
      ;;
    1)
      if [ "$last" = "$STOPPED_LINE" ]; then
        exit 1
      fi
      remove_bundle || true
      if [ "$unknown" = "1" ]; then
        resolve_sleep_disabled 1
      fi
      exit 1
      ;;
    75)
      exit 75
      ;;
    *)
      say "Overtime --uninstall ended with exit $code. Overtime.app was kept."
      exit 1
      ;;
  esac
}

helper_owns_sleep_setting() {
  local folder="$ROOT_PREFIX/${ROOT_ITEMS[0]}" value
  exists "$folder" || return 1
  sudo -v || return 2
  value="$(sudo /bin/sh -c 'if [ -e "$1" ]; then /usr/bin/plutil -extract owns raw -o - "$1" 2> /dev/null || echo unreadable; else echo missing; fi' sh "$folder/$RECORD_FILE")" || return 2
  case "$value" in
    true) return 0 ;;
    false | missing) return 1 ;;
    *) return 2 ;;
  esac
}

SLEEP_FAILED=0

resolve_sleep_disabled() {
  local repeat_unknown="$1" sleep_disabled owned
  SLEEP_FAILED=0
  sleep_disabled="$(pmset -g 2> /dev/null | awk '$1 == "SleepDisabled" { print $2; exit }' || true)"
  case "$sleep_disabled" in
    0) ;;
    1)
      if [ "$DRY_RUN" -eq 1 ]; then
        would "sudo pmset -a disablesleep 0 if the helper's record says Overtime turned sleep off"
      else
        owned=0
        helper_owns_sleep_setting || owned=$?
        case "$owned" in
          0)
            if sudo pmset -a disablesleep 0; then
              say "Turned system sleep back on."
            else
              say "Couldn't turn system sleep back on. To turn sleep back on, run: sudo pmset -a disablesleep 0"
              SLEEP_FAILED=1
            fi
            ;;
          1)
            say "$NOT_OWNED_LINE"
            ;;
          *)
            if [ "$repeat_unknown" -eq 0 ]; then
              say "$UNKNOWN_OWNER_LINE"
            fi
            SLEEP_FAILED=1
            ;;
        esac
      fi
      ;;
    *)
      if [ "$DRY_RUN" -eq 0 ]; then
        say "$SLEEP_UNREAD_LINE"
        SLEEP_FAILED=1
      fi
      ;;
  esac
}

uninstall_absent() {
  local failed=0 root_safe=1 item path user_failed=0
  if launchctl print "system/$HELPER_LABEL" > /dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      would "sudo launchctl bootout system/$HELPER_LABEL"
    elif sudo launchctl bootout "system/$HELPER_LABEL"; then
      say "Stopped the helper."
    else
      say "Couldn't stop the helper."
      failed=1
      root_safe=0
    fi
  fi

  resolve_sleep_disabled 0
  if [ "$SLEEP_FAILED" -eq 1 ]; then
    failed=1
    root_safe=0
  fi

  if [ "$PURGE" -eq 1 ]; then
    for item in "${USER_ITEMS[@]}"; do
      path="${USER_HOME:?}/$item"
      exists "$path" || continue
      if [ "$DRY_RUN" -eq 1 ]; then
        would "remove $path"
      elif ! rm -rf -- "$path"; then
        user_failed=1
      fi
    done
    set --
    for item in "${ROOT_ITEMS[@]}"; do
      path="$ROOT_PREFIX/$item"
      exists "$path" || continue
      if [ "$DRY_RUN" -eq 1 ]; then
        would "sudo rm -rf -- $path"
      else
        set -- "$@" "$path"
      fi
    done
    if [ "$#" -gt 0 ] && [ "$root_safe" -eq 0 ]; then
      say "$KEPT_ROOT_LINE"
    elif [ "$#" -gt 0 ] && ! sudo rm -rf -- "$@"; then
      say "Couldn't delete Overtime's folders in /Library."
      failed=1
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ "$user_failed" -eq 0 ]; then
        say "Removed settings, state and logs."
      else
        say "Some of Overtime's files couldn't be deleted."
        failed=1
      fi
    fi
  fi

  say "$LOGIN_ITEM_LINE"
  if [ "$failed" -eq 1 ]; then
    say "$PROBLEMS_LINE"
    exit 1
  fi
  exit 0
}

if [ "$APP_ABSENT" -eq 1 ] || ! exists "$APP"; then
  uninstall_absent
fi
uninstall_present
