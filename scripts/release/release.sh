#!/bin/bash
set -euo pipefail

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$RELEASE_DIR/lib/pipeline.sh"
. "$RELEASE_DIR/lib/pin.sh"
. "$RELEASE_DIR/lib/verify.sh"
. "$RELEASE_DIR/lib/cask.sh"

usage() {
  printf 'usage: release.sh --dry-run [--version X.Y.Z] [--out DIR]\n' >&2
  printf '       release.sh --identity SHA1 --version X.Y.Z [--out DIR]\n' >&2
  exit 64
}

MODE=""
IDENTITY=""
VERSION=""
OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      [ -z "$MODE" ] || usage
      MODE="dry-run"
      shift
      ;;
    --identity)
      [ "$#" -ge 2 ] && [ -z "$MODE" ] || usage
      MODE="release"
      IDENTITY="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || usage
      VERSION="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      OUT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$MODE" ] || usage
IDENTITY_PATTERN='^[0-9A-Fa-f]{40}$'
if [ "$MODE" = "release" ]; then
  [[ "$IDENTITY" =~ $IDENTITY_PATTERN ]] || usage
  [ -n "$VERSION" ] || usage
fi

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/overtime-release.XXXXXX")"
elif [ -e "$OUT" ]; then
  if [ ! -d "$OUT" ] || [ -n "$(ls -A "$OUT")" ]; then
    printf 'release: error: --out %s must be a new or empty folder\n' "$OUT" >&2
    exit 64
  fi
else
  mkdir -p "$OUT"
fi
OUT="$(cd "$OUT" && pwd)"
printf 'release: output %s\n' "$OUT"

ot_load_pins
ot_require_tools || exit 1

if [ "$MODE" = "dry-run" ]; then
  unset SPARKLE_ED_PRIVATE_KEY
  IDENTITY="-"
  [ -n "$VERSION" ] || VERSION="$(ot_marketing_version)"
  BUILD="$(ot_build_number "$VERSION")" || exit 1
else
  BUILD="$(ot_build_number "$VERSION")" || exit 1
  ot_check_release_version "$VERSION" "$(ot_marketing_version)" "$(ot_project_build)" || exit 1
  [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || ot_die "SPARKLE_ED_PRIVATE_KEY is not set"
fi
HELPER_VERSION="$(ot_helper_version)" || exit 1
if [ "$MODE" = "dry-run" ]; then
  PIN_DIR="$(ot_pin_dir "$OUT/pin" "$HELPER_VERSION")"
else
  ot_pin_check "$REPO/Pinned/helper" 0 || ot_die "a release needs a current helper pin under Pinned/helper (pin-helper.sh)"
  PIN_DIR="$(ot_pin_dir "$REPO/Pinned/helper" "$HELPER_VERSION")"
fi

printf 'stage: build\n'
ot_build_edkey "$OUT" || exit 1
if [ "$MODE" = "dry-run" ]; then
  KEYSOURCE="$(ot_dry_run_key "$OUT")" || exit 1
  PUBLIC_KEY="$("$OUT/tools/edkey" pub "$KEYSOURCE")" || ot_die "deriving the dry-run public key failed"
else
  KEYSOURCE="env"
  PUBLIC_KEY="$SPARKLE_PUBLIC_ED_KEY"
fi
ot_generate_project "$OUT" || exit 1
ot_resolve_packages "$OUT" || exit 1
ot_check_sparkle_pin "$OUT" || exit 1
APP="$(ot_build_release "$OUT" "$VERSION" "$BUILD" "$PUBLIC_KEY")" || exit 1
if [ "$MODE" = "dry-run" ]; then
  ot_pin_write "$OUT/dd/Build/Products/Release/OvertimeHelper" - "$PIN_DIR" || exit 1
fi
ot_pin_install "$APP" "$PIN_DIR" || exit 1
if [ "$MODE" = "dry-run" ]; then
  ot_pin_negative_control "$OUT" "$PIN_DIR" || exit 1
fi

printf 'stage: thin\n'
ot_thin_sparkle "$APP" || exit 1

printf 'stage: sign\n'
ot_sign_inside_out "$APP" "$IDENTITY" > "$OUT/logs/sign.log" 2>&1 || {
  cat "$OUT/logs/sign.log" >&2
  ot_die "signing failed"
}

printf 'stage: verify\n'
ot_verify_all "$APP" "$MODE" "$VERSION" "$BUILD" "$PUBLIC_KEY" "$OUT" "$PIN_DIR/MANIFEST.json" || exit 1

printf 'stage: package\n'
ot_zip "$APP" "$OUT" "$VERSION" || exit 1
ot_dmg "$APP" "$OUT" "$VERSION" || exit 1
ot_notes "$OUT" "$VERSION" || exit 1

printf 'stage: appcast\n'
ot_appcast "$OUT" "$VERSION" "$APP" "$KEYSOURCE" || exit 1

printf 'stage: checksums\n'
ot_checksums "$OUT" "$VERSION" || exit 1

printf 'stage: cask\n'
ZIP_SHA256="$(ot_zip_sha256 "$OUT" "$VERSION")" || exit 1
ot_render_cask "$REPO/packaging/homebrew/overtime.rb.template" "$VERSION" "$ZIP_SHA256" "$OUT/Casks/overtime.rb" || exit 1

if [ "$MODE" = "dry-run" ]; then
  printf 'release: dry-run complete\n'
else
  printf 'release: complete\n'
fi
