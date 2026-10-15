#!/bin/bash
set -euo pipefail

if [ "${OVERTIME_SCRIPT_TESTS:-}" != "1" ]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
fi
export LC_ALL=C

HEADER="epoch,role,pid,start,cpu_seconds,rss_kib,footprint_bytes"
INTERVAL_LINE='^# interval_seconds=[1-9][0-9]{0,4}$'
SPAN_PATTERN='^[0-9]{1,4}$'

usage() {
  printf 'usage: report.sh [--min-span-hours HOURS] FILE\n' >&2
  exit 64
}

fail() {
  printf 'report: error: %s\n' "$1" >&2
  exit 64
}

MIN_SPAN_HOURS="168"
FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-span-hours)
      [ "$#" -ge 2 ] || usage
      MIN_SPAN_HOURS="$2"
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$FILE" ] && [ -n "$1" ] || usage
      FILE="$1"
      shift
      ;;
  esac
done
[ -n "$FILE" ] || usage
[[ "$MIN_SPAN_HOURS" =~ $SPAN_PATTERN ]] || fail "--min-span-hours must be a whole number of hours from 0 to 9999"
[ -f "$FILE" ] && [ -r "$FILE" ] || fail "$FILE is not a readable file"
FIRST="$(head -n 1 "$FILE")"
SECOND="$(sed -n '2{p;q;}' "$FILE")"
[[ "$FIRST" =~ $INTERVAL_LINE ]] || fail "the first line is not # interval_seconds=<seconds>"
[ "$SECOND" = "$HEADER" ] || fail "the second line is not the sample header"
INTERVAL="${FIRST#\# interval_seconds=}"
STATUS=0

awk -F ',' -v interval="$INTERVAL" -v minspan="$MIN_SPAN_HOURS" '
function centis(value, part) {
  split(value, part, ".")
  return part[1] * 100 + part[2]
}
function valid() {
  if (NF != 7 || $1 !~ /^[0-9]+$/) return 0
  if ($2 == "run") return $3 == "start" && $4 == "-" && $5 == "-" && $6 == "-" && $7 == "-"
  if ($2 != "app" && $2 != "sentinel" && $2 != "helper" && $2 != "overtimed") return 0
  if ($3 == "absent") return $4 == "-" && $5 == "-" && $6 == "-" && $7 == "-"
  if ($3 !~ /^[0-9]+$/ || $4 == "" || $4 == "-") return 0
  if ($5 !~ /^([0-9]+\.[0-9][0-9]|unreadable)$/) return 0
  return $6 ~ /^([0-9]+|unreadable)$/ && $7 ~ /^([0-9]+|unreadable)$/
}
function sift(a, start, end, root, child, pick, swap) {
  root = start
  while (root * 2 <= end) {
    child = root * 2
    pick = root
    if (a[pick] < a[child]) pick = child
    if (child + 1 <= end && a[pick] < a[child + 1]) pick = child + 1
    if (pick == root) return
    swap = a[root]; a[root] = a[pick]; a[pick] = swap
    root = pick
  }
}
function heapsort(a, n, i, swap) {
  for (i = int(n / 2); i >= 1; i--) sift(a, i, n)
  for (i = n; i > 1; i--) {
    swap = a[1]; a[1] = a[i]; a[i] = swap
    sift(a, 1, i - 1)
  }
}
NR <= 2 { next }
{
  if (!valid()) { malformed++; next }
  if ($2 == "run") { runs++; pendingrun = 1; next }
  if (samples == 0 || $1 != lastepoch) {
    samples++
    when[samples] = $1 + 0
    lastepoch = $1
    if (pendingrun) { runbegin[samples] = 1; pendingrun = 0 }
  }
  role = $2
  seen[role] = 1
  if ($3 == "absent") next
  key = $3 SUBSEP $4
  present[samples, role] = 1
  slot = ++count[samples, role]
  keyat[samples, role, slot] = key
  has[samples, role, key] = 1
  if ($5 != "unreadable") cpu[samples, role, key] = centis($5)
  if ($7 == "unreadable") {
    if (role == "app" || role == "sentinel") memunread[samples] = 1
  } else {
    footprints[role, ++footprintcount[role]] = $7 + 0
    if (role == "app") { appsum[samples] += $7; appread[samples] = 1 }
    if (role == "sentinel") sentinelsum[samples] += $7
  }
}
END {
  split("app sentinel helper overtimed", roles, " ")
  for (k = 2; k <= samples; k++) {
    wall = when[k] - when[k - 1]
    gap = wall <= 0 || wall * 2 > interval * 3
    if (gap) gaps++
    if (gap && wall > 0) {
      if (runbegin[k]) {
        unsampled += wall
        if (wall > longest) longest = wall
      } else {
        asleep += wall
      }
    }
    if (!gap) sampled += wall
    appcounted = 0
    intervalused = 0
    for (r = 1; r <= 4; r++) {
      role = roles[r]
      if (!present[k, role]) continue
      counted = 0
      for (i = 1; i <= count[k, role]; i++) {
        key = keyat[k, role, i]
        if (!((k - 1, role, key) in has)) {
          if (present[k - 1, role]) restarts++
          continue
        }
        if (gap) continue
        if (!((k, role, key) in cpu) || !((k - 1, role, key) in cpu)) continue
        if (cpu[k, role, key] < cpu[k - 1, role, key]) continue
        used[role] += cpu[k, role, key] - cpu[k - 1, role, key]
        if (role != "overtimed") intervalused += cpu[k, role, key] - cpu[k - 1, role, key]
        counted = 1
      }
      if (counted) {
        awake[role] += wall
        if (role == "app") appcounted = 1
      }
    }
    if (appcounted) {
      totalawake += wall
      totalused += intervalused
    }
  }
  printf "interval: %d s\n", interval
  printf "samples: %d\n", samples
  printf "sleep gaps excluded: %d\n", gaps
  printf "restarts: %d\n", restarts
  printf "malformed rows: %d\n", malformed
  span = 0
  if (samples > 1 && when[samples] > when[1]) span = when[samples] - when[1]
  printf "runs: %d\n", runs
  printf "span: %d s from the first to the last sample\n", span
  printf "coverage: %d s awake, %d s across sleeps, %d s unsampled (longest %d s)\n", sampled, asleep, unsampled, longest
  if (sampled > 0) printf "app coverage: %d s of %d s awake (%.2f%%)\n", totalawake, sampled, 100 * totalawake / sampled
  else print "app coverage: n/a"
  for (r = 1; r <= 4; r++) {
    role = roles[r]
    if (!seen[role]) { print role ": not seen"; continue }
    line = role ": "
    if (awake[role] > 0) {
      percent = used[role] / awake[role]
      line = line sprintf("cpu %.4f%% over %d s awake", percent, awake[role])
    } else {
      line = line "cpu n/a"
    }
    n = footprintcount[role]
    if (n > 0) {
      split("", sorted)
      for (i = 1; i <= n; i++) sorted[i] = footprints[role, i]
      heapsort(sorted, n)
      rank = int((95 * n + 99) / 100)
      line = line sprintf(", footprint max %d B, p95 %d B", sorted[n], sorted[rank])
    } else {
      line = line ", footprint unreadable"
    }
    print line
  }
  print "helper footprint: needs root, take it by hand (docs/RELEASING.md, Before 1.0.0)"
  peak = 0
  measured = 0
  for (k = 1; k <= samples; k++) {
    if (memunread[k]) { memskipped++; continue }
    if (!appread[k]) continue
    measured++
    sum = appsum[k] + sentinelsum[k]
    sums[measured] = sum
    if (sum > peak) peak = sum
  }
  if (measured > 0) {
    heapsort(sums, measured)
    totalp95 = sums[int((95 * measured + 99) / 100)]
  }
  insufficient = ""
  if (awake["app"] <= 0) insufficient = "no awake interval of the app"
  else if (measured == 0) insufficient = "no sample with a readable footprint of the app and the sentinel"
  else if (span < minspan * 3600) insufficient = sprintf("the record spans %d s, under the %d h minimum", span, minspan)
  else if (longest > 43200) insufficient = sprintf("the sampler was not running for %d s, over 12 h", longest)
  else if (totalawake * 4 < sampled * 3) insufficient = sprintf("the app was counted in %d s of %d s awake, under 75%%", totalawake, sampled)
  if (totalawake > 0) printf "total cpu: %.4f%%\n", totalused / totalawake
  else print "total cpu: n/a"
  printf "memory samples: %d measured, %d skipped as unreadable\n", measured, memskipped
  if (measured > 0) {
    printf "total memory max: %d B\n", peak
    printf "total memory p95: %d B\n", totalp95
  } else {
    print "total memory max: n/a"
    print "total memory p95: n/a"
  }
  print "budget: cpu under 0.1000%, memory under 40000000 B"
  printf "coverage needed: a span of at least %d h, no gap over 12 h without a sampler running, and the app counted in at least 75%% of the awake time\n", minspan
  if (insufficient != "") {
    print "insufficient: " insufficient
    print "verdict: INSUFFICIENT"
    exit 12
  }
  if (totalused * 10 < totalawake && peak < 40000000) { print "verdict: PASS"; exit 10 }
  print "verdict: FAIL"
  exit 11
}
' "$FILE" || STATUS=$?

case "$STATUS" in
  10) exit 0 ;;
  11) exit 1 ;;
  12) exit 2 ;;
  *)
    printf 'report: error: awk failed with status %s before giving a verdict\n' "$STATUS" >&2
    exit 70
    ;;
esac
