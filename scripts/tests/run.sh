#!/bin/bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO/scripts/tests"
REAL_HOME="$HOME"
REAL_GIT="$(command -v git)"
OVERTIME_SCRIPT_TESTS=1
BASE_PATH="$PATH"
export REPO REAL_HOME REAL_GIT OVERTIME_SCRIPT_TESTS

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/overtime-tests.XXXXXX")" || exit 1
ROOT="$(cd "$ROOT" && pwd)"
RESULTS="$ROOT/results"
SELECTED="$ROOT/selected"
: > "$RESULTS"
: > "$SELECTED"

finish() {
  if [ "${KEEP_TEST_OUTPUT:-0}" = "1" ]; then
    printf 'kept test output in %s\n' "$ROOT"
  else
    rm -rf "${ROOT:?}"
  fi
}

if [ "$#" -eq 0 ]; then
  for file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$file" ] || continue
    name="$(basename "$file" .sh)"
    printf '%s\n' "${name#test_}" >> "$SELECTED"
  done
else
  for name in "$@"; do
    if [ ! -f "$TESTS_DIR/test_$name.sh" ]; then
      printf 'run: unknown test %s\n' "$name" >&2
      finish
      exit 64
    fi
    printf '%s\n' "$name" >> "$SELECTED"
  done
fi

record() {
  local status="$1" name="$2"
  printf '%s\t%s\n' "$status" "$name" >> "$RESULTS"
  if [ "$status" = "ok" ]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
  fi
}

run_check() {
  local expect="$1" name="$2" log status
  shift 2
  log="$(mktemp "$ROOT/check.XXXXXX")"
  "$@" > "$log" 2>&1
  status=$?
  if { [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; } || { [ "$expect" = "fail" ] && [ "$status" -ne 0 ]; }; then
    record ok "$name"
  else
    record fail "$name"
    printf '      exit %s, output:\n' "$status"
    tail -20 "$log" | sed 's/^/      | /'
  fi
  return 0
}

check() {
  run_check pass "$@"
}

check_fails() {
  run_check fail "$@"
}

new_sandbox() {
  local tool
  T="$(mktemp -d "$ROOT/t.XXXXXX")" || return 1
  mkdir "$T/home" "$T/root" "$T/bin" "$T/shim"
  for tool in sudo launchctl pmset osascript gh brew git security defaults; do
    ln -s "$TESTS_DIR/shim.sh" "$T/bin/$tool"
  done
  HOME="$T/home"
  CFFIXED_USER_HOME="$T/home"
  OVERTIME_UNINSTALL_ROOT="$T/root"
  SHIM_DIR="$T/shim"
  SHIM_LOG="$T/shim/calls.log"
  PATH="$T/bin:$BASE_PATH"
  : > "$SHIM_LOG"
  export T HOME CFFIXED_USER_HOME OVERTIME_UNINSTALL_ROOT SHIM_DIR SHIM_LOG PATH
}

shim_allow() {
  printf '%s\n' "${2:-0}" > "$SHIM_DIR/$1.code"
  printf '%s' "${3:-}" > "$SHIM_DIR/$1.out"
}

shim_allow_sub() {
  printf '%s\n' "${3:-0}" > "$SHIM_DIR/$1.$2.code"
  printf '%s' "${4:-}" > "$SHIM_DIR/$1.$2.out"
}

shim_calls() {
  awk -F '\t' -v tool="$1" '$1 == tool { print $2 }' "$SHIM_LOG"
}

no_shim_calls() {
  local tool found=0
  for tool in "$@"; do
    if [ -n "$(shim_calls "$tool")" ]; then
      printf 'unexpected %s call: %s\n' "$tool" "$(shim_calls "$tool" | head -1)"
      found=1
    fi
  done
  [ "$found" -eq 0 ]
}

while IFS= read -r name; do
  printf '== %s\n' "$name"
  (. "$TESTS_DIR/test_$name.sh")
  status=$?
  if [ "$status" -ne 0 ]; then
    record fail "test_$name.sh exited with $status"
  fi
done < "$SELECTED"

passed="$(awk -F '\t' '$1 == "ok"' "$RESULTS" | wc -l | tr -d ' ')"
failed="$(awk -F '\t' '$1 == "fail"' "$RESULTS" | wc -l | tr -d ' ')"
finish
if [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]; then
  printf 'ok %s passed, 0 failed\n' "$passed"
  exit 0
fi
printf 'FAIL %s passed, %s failed\n' "$passed" "$failed"
exit 1
