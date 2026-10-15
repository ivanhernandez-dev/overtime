#!/bin/bash
set -euo pipefail

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$RELEASE_DIR/lib/pipeline.sh"
. "$RELEASE_DIR/lib/pin.sh"

usage() {
  printf 'usage: pin-helper.sh --identity ID --out DIR [--helper PATH]\n' >&2
  printf '       pin-helper.sh --check [--allow-missing] [--pin-root DIR]\n' >&2
  exit 64
}

CHECK=0
ALLOW_MISSING=0
IDENTITY=""
OUT=""
HELPER=""
PIN_ROOT=""
PIN_FLAGS=0
CHECK_FLAGS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      CHECK=1
      shift
      ;;
    --allow-missing)
      ALLOW_MISSING=1
      CHECK_FLAGS=1
      shift
      ;;
    --pin-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      PIN_ROOT="$2"
      CHECK_FLAGS=1
      shift 2
      ;;
    --identity)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      IDENTITY="$2"
      PIN_FLAGS=1
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      OUT="$2"
      PIN_FLAGS=1
      shift 2
      ;;
    --helper)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      HELPER="$2"
      PIN_FLAGS=1
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

ot_load_pins

if [ "$CHECK" -eq 1 ]; then
  [ "$PIN_FLAGS" -eq 0 ] || usage
  for tool in git jq codesign shasum; do
    command -v "$tool" > /dev/null 2>&1 || ot_die "missing tool: $tool"
  done
  if ot_pin_check "${PIN_ROOT:-$REPO/Pinned/helper}" "$ALLOW_MISSING"; then
    exit 0
  fi
  exit 1
fi

[ "$CHECK_FLAGS" -eq 0 ] || usage
[ -n "$IDENTITY" ] && [ -n "$OUT" ] || usage
IDENTITY_PATTERN='^[0-9A-Fa-f]{40}$'
[ "$IDENTITY" = "-" ] || [[ "$IDENTITY" =~ $IDENTITY_PATTERN ]] || usage
if [ -e "$OUT" ] && { [ ! -d "$OUT" ] || [ -n "$(ls -A "$OUT")" ]; }; then
  printf 'pin: error: --out %s must be a new or empty folder\n' "$OUT" >&2
  exit 64
fi

for tool in git jq codesign shasum xcodebuild; do
  command -v "$tool" > /dev/null 2>&1 || ot_die "missing tool: $tool"
done
ot_pin_require_clean_sources || exit 1

if [ -z "$HELPER" ]; then
  ot_require_tools || exit 1
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/overtime-pin.XXXXXX")"
  BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
  printf 'pin: building the Release helper in %s\n' "$BUILD_DIR"
  ot_generate_project "$BUILD_DIR" || exit 1
  ot_resolve_packages "$BUILD_DIR" || exit 1
  ot_check_sparkle_pin "$BUILD_DIR" || exit 1
  ot_build_release "$BUILD_DIR" "$(ot_marketing_version)" "$(ot_project_build)" "$SPARKLE_PUBLIC_ED_KEY" > /dev/null \
    || exit 1
  HELPER="$BUILD_DIR/dd/Build/Products/Release/OvertimeHelper"
fi
[ -f "$HELPER" ] || ot_die "no helper at $HELPER"

ot_pin_write "$HELPER" "$IDENTITY" "$OUT" || exit 1
ot_pin_check_binary "$OUT/OvertimeHelper" "$OUT/MANIFEST.json" || ot_die "the new pin does not pass its own check"
if [ -n "${BUILD_DIR:-}" ]; then
  rm -rf "${BUILD_DIR:?}"
fi
printf 'pin: %s/OvertimeHelper and MANIFEST.json written; commit them under Pinned/helper/v%s\n' \
  "$OUT" "$(ot_helper_version)"
