#!/bin/bash
set -euo pipefail

if [ "${OVERTIME_SCRIPT_TESTS:-}" != "1" ]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
fi
export LC_ALL=C

HEADER="epoch,role,pid,start,cpu_seconds,rss_kib,footprint_bytes"
APP_ROOT="/Applications/Overtime.app/Contents/MacOS"
DIGITS='^[0-9]+$'
INTERVAL_PATTERN='^[1-9][0-9]{1,4}$'
DURATION_PATTERN='^[1-9][0-9]{0,8}$'
SHORT_TIME='^[0-9]+:[0-9][0-9](\.[0-9]+)?$'
LONG_TIME='^[0-9]+:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?$'

usage() {
  printf 'usage: sample.sh --out FILE [--interval SECONDS] [--duration SECONDS] [--append]\n' >&2
  exit 64
}

fail() {
  printf 'sample: error: %s\n' "$1" >&2
  exit 64
}

die() {
  printf 'sample: error: %s\n' "$1" >&2
  exit 1
}

OUT=""
INTERVAL="60"
DURATION=""
APPEND="0"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --append)
      APPEND="1"
      shift
      ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      OUT="$2"
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || usage
      INTERVAL="$2"
      shift 2
      ;;
    --duration)
      [ "$#" -ge 2 ] || usage
      DURATION="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$OUT" ] || usage
[[ "$INTERVAL" =~ $INTERVAL_PATTERN ]] && [ "$INTERVAL" -le 86400 ] || fail "--interval must be a whole number of seconds from 10 to 86400"
if [ -n "$DURATION" ]; then
  [[ "$DURATION" =~ $DURATION_PATTERN ]] || fail "--duration must be a whole number of seconds of at least 1"
fi

[ ! -L "$OUT" ] || fail "--out $OUT is a symbolic link"
if [ -e "$OUT" ] && [ ! -f "$OUT" ]; then
  fail "--out $OUT is not a regular file"
fi
OUT_FOLDER="$(dirname "$OUT")"
if [ ! -d "$OUT_FOLDER" ] || [ ! -w "$OUT_FOLDER" ]; then
  fail "the folder $OUT_FOLDER is missing or not writable, and the sampler writes --out and its lock there"
fi

LOCK="$OUT.lock"
OWNS_LOCK="0"

release_lock() {
  if [ "$OWNS_LOCK" = "1" ]; then
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2> /dev/null || true
  fi
}

lock_holder_samples() {
  local holder="$1" command
  [ "$holder" != "$$" ] || return 1
  [[ "$holder" =~ $DIGITS ]] || return 1
  command="$(ps -p "$holder" -o command= < /dev/null 2> /dev/null)" || return 1
  case "$command" in
    *sample.sh*) return 0 ;;
  esac
  return 1
}

lock_identity() {
  local inode holder
  inode="$(ls -di "$1" 2> /dev/null | awk '{ print $1 }')" || inode=""
  holder="$(cat "$1/pid" 2> /dev/null || true)"
  printf '%s %s\n' "$inode" "$holder"
}

drop_lock_folder() {
  rm -f "$1/pid"
  rmdir "$1" 2> /dev/null || true
}

replace_stale_lock() {
  local seen="$1" fresh="$LOCK.new.$$" aside="$LOCK.stale.$$" extra
  if [ -e "$fresh" ] || [ -L "$fresh" ] || [ -e "$aside" ] || [ -L "$aside" ]; then
    fail "$fresh or $aside is left from an earlier sampler; remove it and run again"
  fi
  extra="$(ls -A "$LOCK" 2> /dev/null | grep -vx pid || true)"
  [ -z "$extra" ] || fail "could not replace the stale lock $LOCK: it holds more than a pid"
  mkdir "$fresh" 2> /dev/null || fail "could not create $fresh to replace the stale lock $LOCK"
  printf '%s\n' "$$" > "$fresh/pid"
  if ! mv "$LOCK" "$aside" 2> /dev/null; then
    drop_lock_folder "$fresh"
    fail "another sampler took the lock $LOCK"
  fi
  if [ "$(lock_identity "$aside")" != "$seen" ]; then
    [ -e "$LOCK" ] || [ -L "$LOCK" ] || mv "$aside" "$LOCK" 2> /dev/null || true
    drop_lock_folder "$fresh"
    fail "another sampler took the lock $LOCK"
  fi
  drop_lock_folder "$aside"
  if [ -e "$LOCK" ] || [ -L "$LOCK" ] || ! mv "$fresh" "$LOCK" 2> /dev/null; then
    drop_lock_folder "$fresh"
    fail "another sampler took the lock $LOCK"
  fi
  if [ -e "$LOCK/${fresh##*/}" ]; then
    drop_lock_folder "$LOCK/${fresh##*/}"
    fail "another sampler took the lock $LOCK"
  fi
  OWNS_LOCK="1"
}

take_lock() {
  local seen
  if mkdir "$LOCK" 2> /dev/null; then
    OWNS_LOCK="1"
    printf '%s\n' "$$" > "$LOCK/pid"
    return 0
  fi
  if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -d "$LOCK" ]; }; then
    fail "$LOCK is in the way of the sampler's lock"
  fi
  [ -d "$LOCK" ] || fail "could not create the lock $LOCK; run the sampler again"
  seen="$(lock_identity "$LOCK")"
  if [ -z "${seen#* }" ]; then
    sleep 1
    seen="$(lock_identity "$LOCK")"
  fi
  if lock_holder_samples "${seen#* }"; then
    fail "another sampler (pid ${seen#* }) is still recording --out $OUT; stop it first, or name a new file"
  fi
  replace_stale_lock "$seen"
}

trap release_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
take_lock

if [ -s "$OUT" ]; then
  [ "$APPEND" = "1" ] || fail "--out $OUT already holds a record; name a new file, or add --append to continue it after a restart"
  FIRST_LINE="$(head -n 1 "$OUT")"
  SECOND_LINE="$(sed -n '2{p;q;}' "$OUT")"
  if [ "$FIRST_LINE" != "# interval_seconds=$INTERVAL" ] || [ "$SECOND_LINE" != "$HEADER" ]; then
    fail "--out $OUT is not a record of this sampler taken every $INTERVAL s"
  fi
else
  [ "$APPEND" = "0" ] || fail "--append needs an existing record, and --out $OUT holds none"
  printf '# interval_seconds=%s\n%s\n' "$INTERVAL" "$HEADER" >> "$OUT"
fi

SELF_UID="$(id -u)"
[[ "$SELF_UID" =~ $DIGITS ]] || die "could not read the user id"

cpu_seconds() {
  local value="$1"
  if [[ "$value" =~ $SHORT_TIME ]] || [[ "$value" =~ $LONG_TIME ]]; then
    awk -v t="$value" 'BEGIN {
      n = split(t, part, ":")
      if (n == 2) { s = part[1] * 60 + part[2] } else { s = part[1] * 3600 + part[2] * 60 + part[3] }
      printf "%.2f\n", s
    }'
  else
    printf 'unreadable\n'
  fi
}

footprint_bytes() {
  local pid="$1" uid="$2" text value
  if [ "$uid" != "$SELF_UID" ] || ! [[ "$pid" =~ $DIGITS ]]; then
    printf 'unreadable\n'
    return 0
  fi
  if ! text="$(footprint -f bytes "$pid" < /dev/null 2> /dev/null)"; then
    printf 'unreadable\n'
    return 0
  fi
  value="$(printf '%s\n' "$text" | awk 'match($0, /Footprint: [0-9]+ B/) { print substr($0, RSTART + 11, RLENGTH - 13); exit }')"
  if [[ "$value" =~ $DIGITS ]]; then
    printf '%s\n' "$value"
  else
    printf 'unreadable\n'
  fi
}

sample_once() {
  local epoch="$1" listing pid uid cputime rss d1 d2 d3 d4 d5 comm role start cpu memory seen=" " wanted
  if ! listing="$(ps -axo pid=,uid=,time=,rss=,lstart=,comm= < /dev/null)"; then
    printf 'sample: warning: ps failed, sample at %s skipped\n' "$epoch" >&2
    return 0
  fi
  while read -r pid uid cputime rss d1 d2 d3 d4 d5 comm; do
    case "$comm" in
      "$APP_ROOT/Overtime") role="app" ;;
      "$APP_ROOT/overtime-sentinel") role="sentinel" ;;
      "$APP_ROOT/OvertimeHelper") role="helper" ;;
      */overtimed) role="overtimed" ;;
      *) continue ;;
    esac
    [[ "$pid" =~ $DIGITS ]] && [[ "$uid" =~ $DIGITS ]] || continue
    start="$d1 $d2 $d3 $d4 $d5"
    case "$start" in
      *,*) start="unreadable" ;;
    esac
    cpu="$(cpu_seconds "$cputime")"
    [[ "$rss" =~ $DIGITS ]] || rss="unreadable"
    memory="$(footprint_bytes "$pid" "$uid")"
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$epoch" "$role" "$pid" "$start" "$cpu" "$rss" "$memory" >> "$OUT"
    seen="$seen$role "
  done <<< "$listing"
  for wanted in app sentinel helper; do
    case "$seen" in
      *" $wanted "*) ;;
      *) printf '%s,%s,absent,-,-,-,-\n' "$epoch" "$wanted" >> "$OUT" ;;
    esac
  done
}

START=""
while :; do
  NOW="$(date +%s)"
  [[ "$NOW" =~ $DIGITS ]] || die "date did not print an epoch"
  if [ -z "$START" ]; then
    START="$NOW"
    printf '%s,run,start,-,-,-,-\n' "$NOW" >> "$OUT"
  fi
  sample_once "$NOW"
  if [ -n "$DURATION" ] && [ $((NOW - START)) -ge "$DURATION" ]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
