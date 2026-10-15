#!/bin/bash

SAMPLE="$REPO/scripts/energy/sample.sh"
REPORT="$REPO/scripts/energy/report.sh"
HEADER="epoch,role,pid,start,cpu_seconds,rss_kib,footprint_bytes"
ME="$(id -u)"
APP_PATH="/Applications/Overtime.app/Contents/MacOS/Overtime"
SENTINEL_PATH="/Applications/Overtime.app/Contents/MacOS/overtime-sentinel"
HELPER_PATH="/Applications/Overtime.app/Contents/MacOS/OvertimeHelper"
DAEMON_PATH="/Applications/Fixture Tools/overtimed"
DECOY_PATH="/Applications/OvertimeSpike.app/Contents/MacOS/OvertimeSpike"
LOOKALIKE_PATH="/Applications/Other Overtime.app/Contents/MacOS/Overtime"
SYSTEM_PATH="/System/Library/CoreServices/Fixture Agent.app/Contents/MacOS/Fixture Agent"
START_APP="Sun Oct 11 04:28:28 2026"

write_fake() {
  printf '#!/bin/bash\nFX=%q\n%s\n' "$T/fx" "$2" > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

sandbox() {
  new_sandbox
  mkdir "$T/fx"
  OUTPUT="$T/output"
  STATUS=""
  CSV="$T/record.csv"
  write_fake ps '
if [ "${1:-}" = "-p" ]; then
  printf "%s\n" "$*" >> "$FX/ps.probes"
  if [ -f "$FX/takeover.pid" ]; then cat "$FX/takeover.pid" > "$FX/../record.csv.lock/pid"; fi
  if [ -f "$FX/alive.${2:-none}" ]; then cat "$FX/alive.${2:-none}"; exit 0; fi
  exit 1
fi
n=$(( $(cat "$FX/ps.count" 2> /dev/null || printf 0) + 1 ))
printf "%s\n" "$n" > "$FX/ps.count"
printf "%s\n" "${LC_ALL:-unset}" > "$FX/locale"
printf "%s\n" "$*" >> "$FX/ps.args"
if [ -f "$FX/ps.$n" ]; then cat "$FX/ps.$n"; else cat "$FX/ps.1"; fi'
  write_fake footprint '
printf "%s\n" "$*" >> "$FX/footprint.args"
printf "%s\n" "${3:-}" >> "$FX/footprint.calls"
if [ -f "$FX/footprint.fail" ]; then printf "footprint: error\n" >&2; exit 1; fi
if [ -f "$FX/footprint.${3:-none}" ]; then cat "$FX/footprint.${3:-none}"; exit 0; fi
printf "footprint: Unable to find process %s (try as root?)\n" "${3:-}" >&2
exit 1'
  write_fake date '
n=$(( $(cat "$FX/date.count" 2> /dev/null || printf 0) + 1 ))
printf "%s\n" "$n" > "$FX/date.count"
printf "%s\n" "$*" >> "$FX/date.args"
line="$(sed -n "${n}p" "$FX/epochs")"
[ -n "$line" ] || { printf "fake date: out of epochs\n" >&2; exit 1; }
printf "%s\n" "$line"'
  write_fake sleep '
printf "%s\n" "$*" >> "$FX/sleep.calls"
if [ -f "$FX/late.pid" ] && [ -d "$FX/../record.csv.lock" ]; then cat "$FX/late.pid" > "$FX/../record.csv.lock/pid"; fi
if [ -f "$FX/../record.csv.lock/pid" ]; then cat "$FX/../record.csv.lock/pid" >> "$FX/lock.seen"; fi'
}

epochs() {
  printf '%s\n' "$@" > "$T/fx/epochs"
}

ps_line() {
  printf '%6s %5s %10s %6s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

ps_fixture() {
  local n="$1"
  shift
  printf '%s\n' "$@" > "$T/fx/ps.$n"
}

footprint_fixture() {
  printf 'Fixture [%s]: 64-bit    Footprint: %s B (16384 bytes per page)\n' "$1" "$2" > "$T/fx/footprint.$1"
}

standard_listing() {
  ps_fixture "$1" \
    "$(ps_line 1 0 "12:03.10" 9000 "Sat Oct 10 07:00:00 2026" "/sbin/launchd")" \
    "$(ps_line 501 "$ME" "$2" 40000 "$START_APP" "$APP_PATH")" \
    "$(ps_line 502 "$ME" "0:01.00" 3000 "Sun Oct  4 09:05:07 2026" "$SENTINEL_PATH")" \
    "$(ps_line 777 "$ME" "3:00.00" 50000 "Fri Oct  9 10:00:00 2026" "$DECOY_PATH")" \
    "$(ps_line 778 "$ME" "0:00.10" 1000 "Fri Oct  9 10:00:00 2026" "$LOOKALIKE_PATH")" \
    "$(ps_line 88 0 "1:02:03.40" 8000 "Sat Oct 10 07:00:01 2026" "$SYSTEM_PATH")"
}

PRIVILEGED_RUNS=0
RUNS=0

note_privileged_calls() {
  RUNS=$((RUNS + 1))
  no_shim_calls sudo launchctl pmset > /dev/null || PRIVILEGED_RUNS=$((PRIVILEGED_RUNS + 1))
}

run_sample() {
  /bin/bash "$SAMPLE" "$@" > "$OUTPUT" 2>&1
  STATUS=$?
  note_privileged_calls
}

run_report() {
  /bin/bash "$REPORT" "$@" > "$OUTPUT" 2>&1
  STATUS=$?
  note_privileged_calls
}

status_is() {
  [ "$STATUS" -eq "$1" ] || { printf 'status %s\n' "$STATUS"; cat "$OUTPUT"; return 1; }
}

output_has() {
  grep -qxF -- "$1" "$OUTPUT" || { cat "$OUTPUT"; return 1; }
}

output_line_has() {
  grep -F -- "$1" "$OUTPUT" | grep -qF -- "$2" || { cat "$OUTPUT"; return 1; }
}

csv_is() {
  [ "$(cat "$CSV")" = "$1" ] || { printf 'record:\n%s\n' "$(cat "$CSV")"; return 1; }
}

csv_has() {
  grep -qxF -- "$1" "$CSV" || { printf 'record:\n%s\n' "$(cat "$CSV")"; return 1; }
}

csv_lacks() {
  ! grep -qF -- "$1" "$CSV" || { printf 'record:\n%s\n' "$(cat "$CSV")"; return 1; }
}

calls_are() {
  [ "$(cat "$T/fx/$1" 2> /dev/null)" = "$2" ] || { printf '%s:\n%s\n' "$1" "$(cat "$T/fx/$1" 2> /dev/null)"; return 1; }
}

never_asked_footprint_about() {
  local pid
  for pid in "$@"; do
    if grep -qxF -- "$pid" "$T/fx/footprint.calls" 2> /dev/null; then
      printf 'footprint was asked about %s\n' "$pid"
      return 1
    fi
  done
}

write_csv() {
  printf '# interval_seconds=%s\n%s\n' "$1" "$HEADER" > "$CSV"
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >> "$CSV"
}

two_samples() {
  write_csv 60 \
    "1000,app,501,$START_APP,12.50,40000,23000000" \
    "1000,sentinel,502,Sun Oct 4 09:05:07 2026,1.00,3000,2000000" \
    "1000,helper,absent,-,-,-,-" \
    "1060,app,501,$START_APP,$1,40000,23000000" \
    "1060,sentinel,502,Sun Oct 4 09:05:07 2026,1.00,3000,2000000" \
    "1060,helper,absent,-,-,-,-"
}

sandbox
epochs 1000 1060 1120
standard_listing 1 "0:12.50"
standard_listing 2 "0:12.51"
footprint_fixture 501 23000000
footprint_fixture 502 2000000
footprint_fixture 777 61000000
footprint_fixture 778 1000000
run_sample --out "$CSV" --interval 60 --duration 120
check "sample: a run over 120 s exits 0" status_is 0
check "sample: the record holds the interval line, the header, a run row, and app, sentinel and absent helper rows per sample, with a last sample once the duration is reached" csv_is "# interval_seconds=60
$HEADER
1000,run,start,-,-,-,-
1000,app,501,$START_APP,12.50,40000,23000000
1000,sentinel,502,Sun Oct 4 09:05:07 2026,1.00,3000,2000000
1000,helper,absent,-,-,-,-
1060,app,501,$START_APP,12.51,40000,23000000
1060,sentinel,502,Sun Oct 4 09:05:07 2026,1.00,3000,2000000
1060,helper,absent,-,-,-,-
1120,app,501,$START_APP,12.50,40000,23000000
1120,sentinel,502,Sun Oct 4 09:05:07 2026,1.00,3000,2000000
1120,helper,absent,-,-,-,-"
check "sample: the app's ps line becomes the exact app row" csv_has "1000,app,501,$START_APP,12.50,40000,23000000"
only_overtime_recorded() {
  csv_lacks ",777," && csv_lacks ",778," && csv_lacks ",88," && csv_lacks ",1," && csv_lacks "/" && csv_lacks "Spike" \
    && never_asked_footprint_about 777 778 88 1
}
check "sample: decoys, look-alikes and system processes are never recorded or asked about, and no path is written" only_overtime_recorded
check "sample: sleep runs with the interval after each sample, twice in all" calls_are sleep.calls "60
60"
check "sample: no privileged tool is called" no_shim_calls sudo launchctl pmset

DEBUG_ROOT="/Volumes/Fixture/DerivedData/Overtime-gate/Build/Products/Debug/Overtime.app/Contents/MacOS"
BUILD_APP_PATH="/Volumes/Fixture/overtime/build/Release/Overtime.app/Contents/MacOS/Overtime"
HOME_APP_PATH="/Volumes/Fixture/Applications/Overtime.app/Contents/MacOS/Overtime"
sandbox
epochs 1000 1060
ps_fixture 1 \
  "$(ps_line 501 "$ME" "0:12.50" 40000 "$START_APP" "$APP_PATH")" \
  "$(ps_line 601 "$ME" "0:30.00" 90000 "Mon Oct 12 09:00:00 2026" "$DEBUG_ROOT/Overtime")" \
  "$(ps_line 602 "$ME" "0:01.00" 3000 "Mon Oct 12 09:00:00 2026" "$DEBUG_ROOT/overtime-sentinel")" \
  "$(ps_line 603 0 "0:02.00" 5000 "Mon Oct 12 09:00:00 2026" "$DEBUG_ROOT/OvertimeHelper")" \
  "$(ps_line 604 "$ME" "0:05.00" 9000 "Mon Oct 12 09:00:00 2026" "$BUILD_APP_PATH")" \
  "$(ps_line 605 "$ME" "0:06.00" 9000 "Mon Oct 12 09:00:00 2026" "$HOME_APP_PATH")"
footprint_fixture 501 23000000
footprint_fixture 601 90000000
footprint_fixture 602 2000000
footprint_fixture 604 9000000
footprint_fixture 605 9000000
run_sample --out "$CSV" --interval 60 --duration 60
only_the_installed_bundle() {
  status_is 0 && csv_has "1000,app,501,$START_APP,12.50,40000,23000000" \
    && csv_has "1000,sentinel,absent,-,-,-,-" && csv_has "1000,helper,absent,-,-,-,-" \
    && csv_lacks ",601," && csv_lacks ",602," && csv_lacks ",603," && csv_lacks ",604," && csv_lacks ",605," \
    && never_asked_footprint_about 601 602 603 604 605
}
check "sample: a Debug build, a build folder or another Overtime.app is never recorded; only /Applications/Overtime.app counts" only_the_installed_bundle

sandbox
two_samples 12.51
run_report --min-span-hours 0 "$CSV"
small_rise_passes() {
  status_is 0 && output_has "total cpu: 0.0167%" && output_has "total memory max: 25000000 B" && output_has "verdict: PASS"
}
check "report: a small CPU rise passes" small_rise_passes

sandbox
two_samples 12.62
run_report --min-span-hours 0 "$CSV"
large_rise_fails() {
  status_is 1 && output_has "total cpu: 0.2000%" && output_has "verdict: FAIL"
}
check "report: a CPU rise of 0.2% of a core fails" large_rise_fails
check "report: no privileged tool is called" no_shim_calls sudo launchctl pmset

SENTINEL_START="Sun Oct 4 09:05:07 2026"
SENTINEL_FP=2000000
RESTART_START="Mon Oct 12 08:00:00 2026"

app_csv() {
  local interval="$1" entry epoch cpu fp
  shift
  write_csv "$interval"
  for entry in "$@"; do
    read -r epoch cpu fp <<< "$entry"
    printf '%s,app,501,%s,%s,40000,%s\n' "$epoch" "$START_APP" "$cpu" "$fp" >> "$CSV"
    printf '%s,sentinel,502,%s,1.00,3000,%s\n' "$epoch" "$SENTINEL_START" "$SENTINEL_FP" >> "$CSV"
    printf '%s,helper,absent,-,-,-,-\n' "$epoch" >> "$CSV"
  done
}

verdict_is() {
  status_is "$1" && output_has "verdict: $2"
}

no_negative_cpu() {
  ! grep -qE '^[a-z]+: cpu -' "$OUTPUT" || { cat "$OUTPUT"; return 1; }
}

has_a_verdict() {
  grep -qE '^verdict: (PASS|FAIL|INSUFFICIENT)$' "$OUTPUT" || { cat "$OUTPUT"; return 1; }
}

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.07 23000000" "4660 10.08 23000000" "4720 10.15 23000000"
run_report --min-span-hours 0 "$CSV"
gap_is_excluded() {
  output_has "sleep gaps excluded: 1" && output_has "total cpu: 0.1167%" && verdict_is 1 FAIL
}
check "report, sleep gap: the interval across a sleep is excluded and counted, and the awake average fails" gap_is_excluded

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000" "1030 10.02 23000000" "1090 10.03 23000000"
run_report --min-span-hours 0 "$CSV"
check "report, clock back: an interval where the clock went back is excluded and counted" output_has "sleep gaps excluded: 1"

sandbox
write_csv 60 \
  "1000,app,501,$START_APP,50.00,40000,23000000" \
  "1000,helper,absent,-,-,-,-" \
  "1060,app,601,$RESTART_START,0.50,40000,23000000" \
  "1060,helper,absent,-,-,-,-" \
  "1120,app,601,$RESTART_START,0.51,40000,23000000" \
  "1120,helper,absent,-,-,-,-"
run_report --min-span-hours 0 "$CSV"
restart_is_excluded() {
  output_has "restarts: 1" && no_negative_cpu
}
check "report, restart: a changed pid and start time is counted and never gives negative CPU" restart_is_excluded

sandbox
epochs 1000 1060
ps_fixture 1 \
  "$(ps_line 501 "$ME" "0:12.50" 40000 "$START_APP" "$APP_PATH")" \
  "$(ps_line 900 0 "0:02.00" 5000 "Mon Oct 12 09:00:00 2026" "$HELPER_PATH")"
footprint_fixture 501 23000000
footprint_fixture 900 4000000
run_sample --out "$CSV" --interval 60 --duration 60
helper_cpu_without_footprint() {
  csv_has "1000,helper,900,Mon Oct 12 09:00:00 2026,2.00,5000,unreadable" && never_asked_footprint_about 900
}
check "sample, helper as root: CPU is recorded, footprint is unreadable and never asked" helper_cpu_without_footprint

sandbox
epochs 1000 1060
ps_fixture 1 "$(ps_line 501 "$ME" "0:12.50" 40000 "$START_APP" "$APP_PATH")"
footprint_fixture 501 23000000
: > "$T/fx/footprint.fail"
run_sample --out "$CSV" --interval 60 --duration 60
check "sample, failing footprint: the app's footprint is unreadable" csv_has "1000,app,501,$START_APP,12.50,40000,unreadable"

sandbox
epochs 1000 1060
ps_fixture 1 "$(ps_line 501 "$ME" "1-02:03:04" 40000 "$START_APP" "$APP_PATH")"
footprint_fixture 501 23000000
run_sample --out "$CSV" --interval 60 --duration 60
check "sample, unknown CPU format: the CPU is unreadable" csv_has "1000,app,501,$START_APP,unreadable,40000,23000000"

sandbox
epochs 1000 1060
ps_fixture 1 "$(ps_line 501 "$ME" "1:02:03.40" 40000 "$START_APP" "$APP_PATH")"
footprint_fixture 501 23000000
run_sample --out "$CSV" --interval 60 --duration 60
check "sample: an hour-long CPU time converts to seconds" csv_has "1000,app,501,$START_APP,3723.40,40000,23000000"

sandbox
epochs 1000 1060
ps_fixture 1 \
  "$(ps_line 501 "$ME" "0:12.50" 40000 "$START_APP" "$APP_PATH")" \
  "$(ps_line 950 "$ME" "4:00.00" 9000 "Mon Oct 12 07:00:00 2026" "$DAEMON_PATH")"
footprint_fixture 501 23000000
footprint_fixture 950 9000000
run_sample --out "$CSV" --interval 60 --duration 60
check "sample, overtimed: a path ending in /overtimed gives an overtimed row" csv_has "1000,overtimed,950,Mon Oct 12 07:00:00 2026,240.00,9000,9000000"

sandbox
write_csv 60 \
  "1000,app,501,$START_APP,10.00,40000,23000000" \
  "1000,overtimed,950,Mon Oct 12 07:00:00 2026,240.00,9000,9000000" \
  "1060,app,501,$START_APP,10.01,40000,23000000" \
  "1060,overtimed,950,Mon Oct 12 07:00:00 2026,270.00,9000,9000000"
run_report --min-span-hours 0 "$CSV"
overtimed_is_reported_not_judged() {
  output_line_has "overtimed: " "cpu 50.0000%" && verdict_is 0 PASS
}
check "report, overtimed: it is reported and never judged" overtimed_is_reported_not_judged

sandbox
write_csv 60
run_report --min-span-hours 0 "$CSV"
check "report, INSUFFICIENT: a record with only the two header lines" verdict_is 2 INSUFFICIENT

sandbox
app_csv 60 "1000 10.00 23000000"
run_report --min-span-hours 0 "$CSV"
check "report, INSUFFICIENT: a single sample" verdict_is 2 INSUFFICIENT

sandbox
app_csv 60 "1000 10.00 23000000" "2000 10.01 23000000" "3000 10.02 23000000"
run_report --min-span-hours 0 "$CSV"
check "report, INSUFFICIENT: every interval is a sleep gap" verdict_is 2 INSUFFICIENT

sandbox
app_csv 60 "1000 10.00 unreadable" "1060 10.01 unreadable" "1120 10.02 unreadable"
run_report --min-span-hours 0 "$CSV"
check "report, INSUFFICIENT: the app footprint is unreadable in every sample" verdict_is 2 INSUFFICIENT

sandbox
SENTINEL_FP=unreadable
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000" "1120 10.02 23000000"
SENTINEL_FP=2000000
run_report --min-span-hours 0 "$CSV"
unreadable_sentinel_is_insufficient() {
  output_has "total memory max: n/a" && output_has "memory samples: 0 measured, 3 skipped as unreadable" \
    && verdict_is 2 INSUFFICIENT
}
check "report, INSUFFICIENT: the sentinel footprint is unreadable in every sample, never read as 0" unreadable_sentinel_is_insufficient

sandbox
write_csv 60 \
  "1000,app,501,$START_APP,10.00,40000,23000000" \
  "1000,sentinel,502,$SENTINEL_START,1.00,3000,2000000" \
  "1060,app,501,$START_APP,10.01,40000,39000000" \
  "1060,sentinel,502,$SENTINEL_START,1.00,3000,unreadable" \
  "1120,app,501,$START_APP,10.02,40000,23000000" \
  "1120,sentinel,502,$SENTINEL_START,1.00,3000,2000000"
run_report --min-span-hours 0 "$CSV"
unreadable_sentinel_sample_is_skipped() {
  output_has "total memory max: 25000000 B" && output_has "memory samples: 2 measured, 1 skipped as unreadable"
}
check "report, memory: a sample with an unreadable sentinel footprint is skipped, not summed with 0" unreadable_sentinel_sample_is_skipped

sandbox
app_csv 60 "1000 10.00 39000000" "1060 10.01 39000000"
run_report --min-span-hours 0 "$CSV"
check "report, memory: app 39000000 plus sentinel 2000000 fails" verdict_is 1 FAIL

sandbox
app_csv 60 "1000 10.00 38000000" "1060 10.01 38000000"
run_report --min-span-hours 0 "$CSV"
exactly_forty_fails() {
  output_has "total memory max: 40000000 B" && verdict_is 1 FAIL
}
check "report, memory: exactly 40000000 bytes fails" exactly_forty_fails

sandbox
app_csv 60 "1000 10.00 37999999" "1060 10.01 37999999"
run_report --min-span-hours 0 "$CSV"
just_under_forty_passes() {
  output_has "total memory max: 39999999 B" && verdict_is 0 PASS
}
check "report, memory: 39999999 bytes passes" just_under_forty_passes

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.06 23000000" "1120 10.12 23000000"
run_report --min-span-hours 0 "$CSV"
exactly_the_cpu_budget_fails() {
  output_has "total cpu: 0.1000%" && verdict_is 1 FAIL
}
check "report, CPU boundary: exactly 0.1000% of a core fails" exactly_the_cpu_budget_fails

split_csv() {
  write_csv 60 \
    "1000,app,501,$START_APP,10.00,40000,23000000" \
    "1000,sentinel,502,$SENTINEL_START,1.00,3000,$SENTINEL_FP" \
    "1000,helper,absent,-,-,-,-" \
    "1060,app,501,$START_APP,$1,40000,23000000" \
    "1060,sentinel,502,$SENTINEL_START,$2,3000,$SENTINEL_FP" \
    "1060,helper,absent,-,-,-,-"
}

sandbox
split_csv 10.01 1.05
run_report --min-span-hours 0 "$CSV"
split_budget_fails() {
  output_has "total cpu: 0.1000%" && verdict_is 1 FAIL
}
check "report, CPU boundary: app 1/60 plus sentinel 5/60, exactly 0.1000% across roles, fails" split_budget_fails

sandbox
split_csv 10.01 1.04
run_report --min-span-hours 0 "$CSV"
split_under_budget_passes() {
  output_has "total cpu: 0.0833%" && verdict_is 0 PASS
}
check "report, CPU boundary: app 1/60 plus sentinel 4/60 passes" split_under_budget_passes

HELPER_START="Mon Oct 12 09:00:00 2026"

week_csv() {
  local app_samples="$1" app_rate="$2" helper="$3" i epoch app_cs helper_cs
  write_csv 3600 "1000,run,start,-,-,-,-"
  for ((i = 0; i <= 168; i++)); do
    epoch=$((1000 + 3600 * i))
    if [ "$i" -lt "$app_samples" ]; then
      app_cs=$((1000 + app_rate * i))
      printf '%s,app,501,%s,%d.%02d,40000,23000000\n' "$epoch" "$START_APP" $((app_cs / 100)) $((app_cs % 100)) >> "$CSV"
      printf '%s,sentinel,502,%s,1.00,3000,%s\n' "$epoch" "$SENTINEL_START" "$SENTINEL_FP" >> "$CSV"
    else
      printf '%s,app,absent,-,-,-,-\n%s,sentinel,absent,-,-,-,-\n' "$epoch" "$epoch" >> "$CSV"
    fi
    if [ "$helper" = "helper" ]; then
      helper_cs=$((200 + 4 * i))
      printf '%s,helper,900,%s,%d.%02d,5000,unreadable\n' "$epoch" "$HELPER_START" $((helper_cs / 100)) $((helper_cs % 100)) >> "$CSV"
    else
      printf '%s,helper,absent,-,-,-,-\n' "$epoch" >> "$CSV"
    fi
  done
}

sandbox
week_csv 25 540 helper
run_report "$CSV"
one_day_with_the_helper_is_insufficient() {
  output_has "app coverage: 86400 s of 604800 s awake (14.29%)" \
    && output_has "insufficient: the app was counted in 86400 s of 604800 s awake, under 75%" \
    && output_line_has "helper: " "over 604800 s awake" && verdict_is 2 INSUFFICIENT
}
check "report, app coverage: a week with the app up one day and the helper up all week is INSUFFICIENT" one_day_with_the_helper_is_insufficient

sandbox
week_csv 25 540 none
run_report "$CSV"
one_day_alone_is_insufficient() {
  output_has "app coverage: 86400 s of 604800 s awake (14.29%)" && verdict_is 2 INSUFFICIENT
}
check "report, app coverage: a week with the app up one day and no helper is INSUFFICIENT" one_day_alone_is_insufficient

sandbox
week_csv 169 540 helper
run_report "$CSV"
week_over_budget_fails() {
  output_has "app coverage: 604800 s of 604800 s awake (100.00%)" && output_has "total cpu: 0.1511%" \
    && verdict_is 1 FAIL
}
check "report, app coverage: a full week with the app at 0.15% of a core and the helper up fails" week_over_budget_fails

sandbox
week_csv 127 432 helper
run_report "$CSV"
helper_time_does_not_dilute() {
  output_has "app coverage: 453600 s of 604800 s awake (75.00%)" && output_has "total cpu: 0.1211%" \
    && verdict_is 1 FAIL
}
check "report, app coverage: time when only the helper runs is left out of the total, so the app at 0.12% for 75% of the week fails" helper_time_does_not_dilute

sandbox
week_csv 126 432 helper
run_report "$CSV"
just_under_three_quarters_is_insufficient() {
  output_has "app coverage: 450000 s of 604800 s awake (74.40%)" && verdict_is 2 INSUFFICIENT
}
check "report, app coverage: the app counted in just under 75% of the sampler's awake time is INSUFFICIENT" just_under_three_quarters_is_insufficient

sandbox
week_csv 127 180 helper
run_report "$CSV"
three_quarters_under_budget_passes() {
  output_has "app coverage: 453600 s of 604800 s awake (75.00%)" && output_has "total cpu: 0.0511%" \
    && verdict_is 0 PASS
}
check "report, app coverage: the app counted in exactly 75% of the sampler's awake time, under budget, passes" three_quarters_under_budget_passes

sandbox
entries=()
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  entries+=("$((1000 + 60 * i)) 10.00 $((i * 1000000))")
done
app_csv 60 "${entries[@]}"
run_report --min-span-hours 0 "$CSV"
p95_is_nearest_rank() {
  output_line_has "app: " "max 20000000 B" && output_line_has "app: " "p95 19000000 B"
}
check "report, p95: twenty samples give the nearest-rank 95th percentile" p95_is_nearest_rank
combined_p95_is_nearest_rank() {
  output_has "total memory max: 22000000 B" && output_has "total memory p95: 21000000 B"
}
check "report, p95: the app plus sentinel sum per sample gets its own nearest-rank 95th percentile" combined_p95_is_nearest_rank

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000"
printf '1120,app,501\n' >> "$CSV"
run_report --min-span-hours 0 "$CSV"
malformed_is_counted() {
  output_has "malformed rows: 1" && has_a_verdict
}
check "report, malformed row: a truncated line is counted and a verdict is still printed" malformed_is_counted

refused_untouched() {
  status_is 64 && [ "$(cat "$1")" = "$2" ] && [ ! -e "$T/fx/ps.count" ] || { printf 'target:\n%s\n' "$(cat "$1" 2> /dev/null)"; return 1; }
}

refused_not_created() {
  status_is 64 && [ ! -e "$1" ] && [ ! -e "$T/fx/ps.count" ] || { ls -la "$T"; return 1; }
}

refused_directory() {
  status_is 64 && [ -z "$(ls -A "$1")" ] && [ ! -e "$T/fx/ps.count" ] || { ls -la "$1"; return 1; }
}

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
printf 'keep\n' > "$T/target"
ln -s "$T/target" "$T/link"
run_sample --out "$T/link" --interval 60 --duration 60
check "sample refusal: an --out that is a symlink exits 64 and leaves the target unchanged" refused_untouched "$T/target" "keep"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
mkdir "$T/folder"
run_sample --out "$T/folder" --interval 60 --duration 60
check "sample refusal: an --out that is a directory exits 64 and writes nothing" refused_directory "$T/folder"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$T/missing/record.csv" --interval 60 --duration 60
missing_folder_named() {
  refused_not_created "$T/missing" && output_line_has "sample: error:" "$T/missing is missing or not writable" \
    && ! grep -qF "in the way" "$OUTPUT"
}
check "sample refusal: an --out in a missing folder exits 64, names the folder and creates nothing" missing_folder_named

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
mkdir "$T/read-only"
chmod 555 "$T/read-only"
run_sample --out "$T/read-only/record.csv" --interval 60 --duration 60
chmod 755 "$T/read-only"
read_only_folder_named() {
  refused_directory "$T/read-only" && output_line_has "sample: error:" "$T/read-only is missing or not writable" \
    && ! grep -qF "in the way" "$OUTPUT"
}
check "sample refusal: an --out in a folder it cannot write exits 64, names the folder and writes nothing" read_only_folder_named

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --interval 60 --duration 60
check "sample refusal: no --out exits 64 without sampling" refused_not_created "$CSV"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$CSV" --interval 0 --duration 60
check "sample refusal: --interval 0 exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$CSV" --interval 9 --duration 60
check "sample refusal: --interval 9, under the 10 s minimum, exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 1000 1010
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
run_sample --out "$CSV" --interval 10 --duration 10
ten_seconds_accepted() {
  status_is 0 && [ "$(head -n 1 "$CSV")" = "# interval_seconds=10" ] && calls_are sleep.calls "10"
}
check "sample: --interval 10, the minimum, is accepted" ten_seconds_accepted

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$CSV" --interval abc --duration 60
check "sample refusal: --interval abc exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$CSV" --interval 60 --duration -5
check "sample refusal: --duration -5 exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
write_csv 30 "900,app,501,$START_APP,12.00,40000,23000000"
BEFORE="$(cat "$CSV")"
run_sample --out "$CSV" --interval 60 --duration 60 --append
check "sample refusal: a record taken at another interval exits 64 and is left unchanged" refused_untouched "$CSV" "$BEFORE"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
app_csv 60 "900 10.00 23000000"
BEFORE="$(cat "$CSV")"
run_sample --out "$CSV" --interval 60 --duration 60
check "sample refusal: an --out that already holds a record exits 64 without --append and is left unchanged" refused_untouched "$CSV" "$BEFORE"

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
run_sample --out "$CSV" --interval 60 --duration 60 --append
check "sample refusal: --append on a missing record exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
footprint_fixture 502 2000000
app_csv 60 "1000 10.00 23000000"
run_sample --out "$CSV" --interval 60 --duration 60 --append
appended_once() {
  status_is 0 && [ "$(grep -c '^# interval_seconds=' "$CSV")" -eq 1 ] && [ "$(grep -c '^epoch,' "$CSV")" -eq 1 ] \
    && csv_has "1000,app,501,$START_APP,10.00,40000,23000000" && csv_has "2000,run,start,-,-,-,-" \
    && csv_has "2000,app,501,$START_APP,12.50,40000,23000000" && [ "$(grep -c ',run,start,' "$CSV")" -eq 1 ] \
    || { cat "$CSV"; return 1; }
}
check "sample, append: --append on a record with the same interval appends one run row and samples only" appended_once
check "guard, locale: ps ran under LC_ALL=C" calls_are locale "C"

SAMPLER_COMMAND="/bin/bash /Volumes/Fixture/overtime/scripts/energy/sample.sh --out /Volumes/Fixture/record.csv"

lock_csv() {
  app_csv 60 "900 10.00 23000000"
  mkdir "$CSV.lock"
  printf '%s\n' "$1" > "$CSV.lock/pid"
}

no_lock_leftovers() {
  local left
  left="$(ls -A "$T" | grep -E '^record\.csv\.lock\.' || true)"
  [ -z "$left" ] || { printf 'left over: %s\n' "$left"; return 1; }
}

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
run_sample --out "$CSV" --interval 60 --duration 60
lock_held_then_released() {
  status_is 0 && grep -qE '^[0-9]+$' "$T/fx/lock.seen" && [ ! -e "$CSV.lock" ] \
    || { printf 'lock seen: %s\n' "$(cat "$T/fx/lock.seen" 2> /dev/null)"; ls -la "$T"; return 1; }
}
check "sample, lock: a run holds a lock with its pid next to the record while it samples, and removes it at the end" lock_held_then_released

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
lock_csv 4242
printf '%s\n' "$SAMPLER_COMMAND" > "$T/fx/alive.4242"
BEFORE="$(cat "$CSV")"
run_sample --out "$CSV" --interval 60 --duration 60 --append
second_sampler_refused() {
  refused_untouched "$CSV" "$BEFORE" && [ "$(cat "$CSV.lock/pid")" = "4242" ] \
    && output_line_has "sample: error:" "pid 4242" && calls_are ps.probes "-p 4242 -o command="
}
check "sample, lock: a second sampler on a record another sampler is still recording exits 64 and leaves the record and the lock alone" second_sampler_refused

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
mkdir "$CSV.lock"
printf '4242\n' > "$CSV.lock/pid"
printf '%s\n' "$SAMPLER_COMMAND" > "$T/fx/alive.4242"
run_sample --out "$CSV" --interval 60 --duration 60
check "sample, lock: a second sampler on a new file another sampler is starting exits 64 and creates nothing" refused_not_created "$CSV"

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
lock_csv 4243
run_sample --out "$CSV" --interval 60 --duration 60 --append
stale_lock_replaced() {
  status_is 0 && csv_has "2000,app,501,$START_APP,12.50,40000,23000000" && [ ! -e "$CSV.lock" ] \
    && grep -qE '^[0-9]+$' "$T/fx/lock.seen" && ! grep -qx 4243 "$T/fx/lock.seen" && no_lock_leftovers
}
check "sample, lock: a lock left by a sampler that is no longer running is replaced" stale_lock_replaced

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
lock_csv 4244
printf '/System/Library/CoreServices/Fixture Agent.app/Contents/MacOS/Fixture Agent\n' > "$T/fx/alive.4244"
run_sample --out "$CSV" --interval 60 --duration 60 --append
reused_pid_replaced() {
  status_is 0 && csv_has "2000,app,501,$START_APP,12.50,40000,23000000" && [ ! -e "$CSV.lock" ]
}
check "sample, lock: a lock whose pid now belongs to another program is replaced" reused_pid_replaced

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
app_csv 60 "900 10.00 23000000"
mkdir "$CSV.lock"
: > "$CSV.lock/pid"
run_sample --out "$CSV" --interval 60 --duration 60 --append
empty_lock_waited_then_replaced() {
  status_is 0 && calls_are sleep.calls "1
60" && csv_has "2000,app,501,$START_APP,12.50,40000,23000000" && [ ! -e "$CSV.lock" ] \
    && grep -qE '^[0-9]+$' "$T/fx/lock.seen" && [ ! -e "$T/fx/ps.probes" ] && no_lock_leftovers
}
check "sample, lock: a lock with an empty pid is read again after 1 s, and replaced only if it is still empty" empty_lock_waited_then_replaced

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
mkdir "$CSV.lock"
printf '4242\n' > "$T/fx/late.pid"
printf '%s\n' "$SAMPLER_COMMAND" > "$T/fx/alive.4242"
run_sample --out "$CSV" --interval 60 --duration 60
starting_sampler_refused() {
  refused_not_created "$CSV" && [ "$(cat "$CSV.lock/pid")" = "4242" ] && calls_are sleep.calls "1" \
    && output_line_has "sample: error:" "pid 4242" && no_lock_leftovers
}
check "sample, lock: a lock whose pid shows up during the 1 s wait belongs to a starting sampler, so the run exits 64 and creates nothing" starting_sampler_refused

own_pid_sampler() {
  printf '#!/bin/bash\nFX=%q\nSAMPLE=%q\nSAMPLER_COMMAND=%q\n%s\n' "$T/fx" "$SAMPLE" "$SAMPLER_COMMAND" \
    'printf "%s\n" "$$" > "$FX/../record.csv.lock/pid"
printf "%s\n" "$SAMPLER_COMMAND" > "$FX/alive.$$"
exec /bin/bash "$SAMPLE" "$@"' > "$T/fx/own-pid-sampler"
  /bin/bash "$T/fx/own-pid-sampler" "$@" > "$OUTPUT" 2>&1
  STATUS=$?
  note_privileged_calls
}

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
app_csv 60 "900 10.00 23000000"
mkdir "$CSV.lock"
own_pid_sampler --out "$CSV" --interval 60 --duration 60 --append
own_pid_is_stale() {
  status_is 0 && csv_has "2000,app,501,$START_APP,12.50,40000,23000000" && [ ! -e "$CSV.lock" ] \
    && [ ! -e "$T/fx/ps.probes" ] && no_lock_leftovers
}
check "sample, lock: a lock left with the sampler's own pid, from before a restart, is stale and replaced" own_pid_is_stale

sandbox
epochs 2000 2060
standard_listing 1 "0:12.50"
lock_csv 4243
printf '4245\n' > "$T/fx/takeover.pid"
BEFORE="$(cat "$CSV")"
run_sample --out "$CSV" --interval 60 --duration 60 --append
changed_lock_kept() {
  refused_untouched "$CSV" "$BEFORE" && [ "$(cat "$CSV.lock/pid")" = "4245" ] \
    && output_line_has "sample: error:" "another sampler took the lock" && no_lock_leftovers
}
check "sample, lock: a stale lock that another sampler replaces before this one can is left to it, and the run exits 64" changed_lock_kept

sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
app_csv 60 "900 10.00 23000000"
run_sample --out "$CSV" --interval 60 --duration 60
refused_leaves_no_lock() {
  status_is 64 && [ ! -e "$CSV.lock" ] || { ls -la "$T"; return 1; }
}
check "sample, lock: a refused run removes its lock" refused_leaves_no_lock

sandbox
run_report --min-span-hours 1
check "report refusal: an option with no record file exits 64" status_is 64

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000"
run_report --min-span-hours abc "$CSV"
check "report refusal: --min-span-hours abc exits 64" status_is 64

span_csv() {
  local last="$1" entries=() epoch
  for ((epoch = 1000; epoch <= last; epoch += 60)); do
    entries+=("$epoch 10.00 23000000")
  done
  app_csv 60 "${entries[@]}"
}

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000"
run_report "$CSV"
default_week_needed() {
  output_has "span: 60 s from the first to the last sample" \
    && output_has "insufficient: the record spans 60 s, under the 168 h minimum" && verdict_is 2 INSUFFICIENT
}
check "report, span: by default a record under 168 h is INSUFFICIENT" default_week_needed

sandbox
span_csv 4600
run_report --min-span-hours 1 "$CSV"
one_hour_passes() {
  output_has "span: 3600 s from the first to the last sample" && verdict_is 0 PASS
}
check "report, span: a record spanning exactly 1 h passes --min-span-hours 1" one_hour_passes

sandbox
span_csv 4540
run_report --min-span-hours 1 "$CSV"
check "report, span: a record spanning 3540 s is INSUFFICIENT under --min-span-hours 1" verdict_is 2 INSUFFICIENT

sandbox
span_csv 1180
sed -n '3,$p' "$CSV" > "$T/rows"
write_csv 60 "1000,run,start,-,-,-,-"
cat "$T/rows" >> "$CSV"
app_csv_tail() {
  local entry epoch cpu fp
  for entry in "$@"; do
    read -r epoch cpu fp <<< "$entry"
    printf '%s,app,501,%s,%s,40000,%s\n' "$epoch" "$START_APP" "$cpu" "$fp" >> "$CSV"
    printf '%s,sentinel,502,%s,1.00,3000,%s\n' "$epoch" "$SENTINEL_START" "$SENTINEL_FP" >> "$CSV"
    printf '%s,helper,absent,-,-,-,-\n' "$epoch" >> "$CSV"
  done
}
cp "$CSV" "$T/base.csv"
printf '44381,run,start,-,-,-,-\n' >> "$CSV"
app_csv_tail "44381 10.00 23000000" "44441 10.00 23000000"
run_report --min-span-hours 0 "$CSV"
unsampled_gap_fails() {
  output_has "runs: 2" && output_has "coverage: 240 s awake, 0 s across sleeps, 43201 s unsampled (longest 43201 s)" \
    && output_has "insufficient: the sampler was not running for 43201 s, over 12 h" && verdict_is 2 INSUFFICIENT
}
check "report, coverage: a gap over 12 h between two sampler runs is INSUFFICIENT" unsampled_gap_fails

cp "$T/base.csv" "$CSV"
printf '44380,run,start,-,-,-,-\n' >> "$CSV"
app_csv_tail "44380 10.00 23000000" "44440 10.00 23000000"
run_report --min-span-hours 0 "$CSV"
twelve_hours_unsampled_passes() {
  output_has "coverage: 240 s awake, 0 s across sleeps, 43200 s unsampled (longest 43200 s)" && verdict_is 0 PASS
}
check "report, coverage: a gap of exactly 12 h between two sampler runs is allowed" twelve_hours_unsampled_passes

cp "$T/base.csv" "$CSV"
app_csv_tail "44381 10.00 23000000" "44441 10.00 23000000"
run_report --min-span-hours 0 "$CSV"
sleep_inside_a_run_passes() {
  output_has "runs: 1" && output_has "coverage: 240 s awake, 43201 s across sleeps, 0 s unsampled (longest 0 s)" \
    && output_has "sleep gaps excluded: 1" && verdict_is 0 PASS
}
check "report, coverage: the same gap inside one sampler run is a sleep and is allowed" sleep_inside_a_run_passes

awk_failure_is_70() {
  status_is 70 && ! grep -q '^verdict:' "$OUTPUT" && output_line_has "report: error:" "awk" || { cat "$OUTPUT"; return 1; }
}

run_report_with_awk() {
  local body="$1"
  shift
  mkdir "$T/awkbin"
  printf '#!/bin/bash\n%s\n' "$body" > "$T/awkbin/awk"
  chmod +x "$T/awkbin/awk"
  PATH="$T/awkbin:$PATH" /bin/bash "$REPORT" "$@" > "$OUTPUT" 2>&1
  STATUS=$?
  note_privileged_calls
}

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000"
run_report_with_awk 'printf "awk: fatal error\n" >&2
exit 2' --min-span-hours 0 "$CSV"
check "report, awk failure: an awk that dies with status 2 exits 70, never INSUFFICIENT" awk_failure_is_70

sandbox
app_csv 60 "1000 10.00 23000000" "1060 10.01 23000000"
run_report_with_awk 'exit 0' --min-span-hours 0 "$CSV"
check "report, awk failure: an awk that exits 0 without a verdict exits 70, never PASS" awk_failure_is_70

sandbox
run_report "$T/missing.csv"
check "report refusal: a missing file exits 64" status_is 64

sandbox
printf '%s\n' "$HEADER" "1000,app,501,$START_APP,10.00,40000,23000000" > "$CSV"
run_report --min-span-hours 0 "$CSV"
check "report refusal: a first line that is not the interval line exits 64" status_is 64

hygienic() {
  local script word found=0
  local fence_1='if [ "${OVERTIME_SCRIPT_TESTS:-}" != "1" ]; then'
  local fence_2='  PATH=/usr/bin:/bin:/usr/sbin:/sbin'
  local fence_3='  export PATH'
  for script in "$SAMPLE" "$REPORT"; do
    for word in sudo powermetrics kill pkill killall eval curl nc wget; do
      if grep -nE "(^|[^A-Za-z0-9_.-])$word([^A-Za-z0-9_-]|\$)" "$script"; then
        printf '%s names %s\n' "$script" "$word"
        found=1
      fi
    done
    if grep -nE 'footprint[^|]*-j' "$script"; then
      printf '%s passes -j to footprint\n' "$script"
      found=1
    fi
    for word in "$fence_1" "$fence_2" "$fence_3" "export LC_ALL=C"; do
      grep -qxF -- "$word" "$script" || { printf '%s lacks: %s\n' "$script" "$word"; found=1; }
    done
  done
  [ "$found" -eq 0 ]
}
check "guard, hygiene: no privileged, signalling or network command, no footprint -j, and the PATH fence and C locale" hygienic

footprint_called_plainly() {
  local line
  [ -s "$T/fx/footprint.args" ] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^-f\ bytes\ [0-9]+$ ]] || { printf 'footprint called with: %s\n' "$line"; return 1; }
  done < "$T/fx/footprint.args"
}
sandbox
epochs 1000 1060
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
run_sample --out "$CSV" --interval 60 --duration 60
check "guard, footprint argv: every call is -f bytes and one digit pid" footprint_called_plainly

runbook_energy_commands() {
  grep -oE '`scripts/energy/[^`]+`' "$REPO/docs/RELEASING.md" | tr -d '`'
}

executable_scripts() {
  local script mode
  for script in scripts/energy/sample.sh scripts/energy/report.sh; do
    [ -x "$REPO/$script" ] || { printf '%s is not executable\n' "$script"; return 1; }
    mode="$("$REAL_GIT" -C "$REPO" ls-files -s -- "$script" | awk '{ print $1 }')"
    [ "$mode" = "100755" ] || { printf '%s has git mode %s\n' "$script" "$mode"; return 1; }
  done
}
check "guard, mode: both energy scripts are executable on disk and 100755 in git" executable_scripts

every_runbook_command_runs_a_script_directly() {
  local command count=0
  while IFS= read -r command; do
    count=$((count + 1))
    case "$command" in
      "scripts/energy/sample.sh "* | "scripts/energy/report.sh "*) ;;
      *) printf 'runbook command: %s\n' "$command"; return 1 ;;
    esac
  done < <(runbook_energy_commands)
  [ "$count" -ge 5 ] || { printf 'only %s runbook energy commands\n' "$count"; return 1; }
}
check "runbook: every energy command runs a script directly, never through a shell" every_runbook_command_runs_a_script_directly

sandbox
HOUR_SAMPLE="$(runbook_energy_commands | grep -F 'sample.sh --out "$HOME/overtime-energy-hour.csv"')"
HOUR_REPORT="$(runbook_energy_commands | grep -F 'report.sh' | grep -F '"$HOME/overtime-energy-hour.csv"')"
hour_epochs=()
for ((epoch = 1000; epoch <= 4600; epoch += 60)); do
  hour_epochs+=("$epoch")
done
epochs "${hour_epochs[@]}"
standard_listing 1 "0:12.50"
footprint_fixture 501 23000000
footprint_fixture 502 2000000
(cd "$REPO" && eval "$HOUR_SAMPLE") > "$T/hour-sample.out" 2>&1
HOUR_SAMPLE_STATUS=$?
(cd "$REPO" && eval "$HOUR_REPORT") > "$OUTPUT" 2>&1
STATUS=$?
hour_runs_as_written() {
  [ "$(printf '%s\n' "$HOUR_SAMPLE" | grep -c .)" -eq 1 ] && [ "$(printf '%s\n' "$HOUR_REPORT" | grep -c .)" -eq 1 ] \
    || { printf 'sample: %s\nreport: %s\n' "$HOUR_SAMPLE" "$HOUR_REPORT"; return 1; }
  [ "$HOUR_SAMPLE_STATUS" -eq 0 ] && [ -s "$HOME/overtime-energy-hour.csv" ] \
    || { printf 'sample status %s\n' "$HOUR_SAMPLE_STATUS"; cat "$T/hour-sample.out"; return 1; }
  output_has "span: 3600 s from the first to the last sample" && verdict_is 0 PASS
}
check "runbook: the one-hour sample and its report run as written, directly from the repository root" hour_runs_as_written

no_privileged_run() {
  [ "$RUNS" -gt 20 ] && [ "$PRIVILEGED_RUNS" -eq 0 ] || { printf 'runs %s, with privileged calls %s\n' "$RUNS" "$PRIVILEGED_RUNS"; return 1; }
}
check "every run: no sudo, launchctl or pmset call" no_privileged_run
