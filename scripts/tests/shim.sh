#!/bin/bash
set -u

name="$(basename "$0")"
first="${1:-}"
second="${2:-}"
printf '%s\t%s\n' "$name" "$*" >> "${SHIM_LOG:?}"

answer() {
  local base="$1" code=0
  if [ -f "$base.code" ] || [ -f "$base.out" ]; then
    [ -f "$base.out" ] && cat "$base.out"
    [ -f "$base.code" ] && code="$(cat "$base.code")"
    exit "$code"
  fi
}

refuse() {
  printf 'shim: %s refused\n' "$*" >&2
  exit 97
}

answer_keyed() {
  local base="$1"
  if [ -n "$first" ] && [ -n "$second" ]; then
    case "$second" in
      */* | .*) ;;
      *) answer "$base.$first.$second" ;;
    esac
  fi
  if [ -n "$first" ]; then
    answer "$base.$first"
  fi
  return 0
}

case "$name" in
  sudo)
    if [ -f "${SHIM_DIR:?}/sudo.validate-only" ] && [ "$#" -gt 0 ]; then
      [ "$first" = "-v" ] && exit 0
      printf 'Sorry, try again.\nsudo: 1 incorrect password attempt\n' >&2
      exit 1
    fi
    if [ -f "${SHIM_DIR:?}/sudo.allow" ] && [ "$#" -gt 0 ]; then
      [ "$first" = "-v" ] && exit 0
      exec "$@"
    fi
    ;;
  git)
    case "$first" in
      push | commit)
        refuse "git $first"
        ;;
      tag)
        case "${2:-}" in
          -l | --list) ;;
          *) refuse "git tag" ;;
        esac
        ;;
    esac
    answer_keyed "${SHIM_DIR:?}/git"
    exec "${REAL_GIT:?}" "$@"
    ;;
esac

answer_keyed "${SHIM_DIR:?}/$name"
answer "${SHIM_DIR:?}/$name"
refuse "$name"
