#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  printf 'usage: install-xcodegen.sh DEST [--zip FILE]\n' >&2
  exit 64
}

fail() {
  printf 'install-xcodegen: %s\n' "$1" >&2
  exit 1
}

DEST=""
ZIP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$ZIP" ] || usage
      ZIP="$2"
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$DEST" ] && [ -n "$1" ] || usage
      DEST="$1"
      shift
      ;;
  esac
done
[ -n "$DEST" ] || usage

. "$REPO/scripts/release/pins.env"

if [ -e "$DEST" ]; then
  [ -d "$DEST" ] && [ ! -L "$DEST" ] && [ -z "$(ls -A "$DEST")" ] || fail "$DEST must be a new or empty folder"
else
  mkdir -p "$DEST"
fi
DEST="$(cd "$DEST" && pwd)"

if [ -z "$ZIP" ]; then
  ZIP="$DEST/xcodegen.zip"
  curl -fsSL --retry 3 -o "$ZIP" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    || fail "downloading XcodeGen $XCODEGEN_VERSION failed"
fi
[ -f "$ZIP" ] || fail "no zip at $ZIP"

DIGEST="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
[ "$DIGEST" = "$XCODEGEN_ZIP_SHA256" ] \
  || fail "xcodegen.zip digest $DIGEST differs from the pinned $XCODEGEN_ZIP_SHA256; nothing extracted"

unzip -q "$ZIP" -d "$DEST" || fail "unzip failed"
BIN="$DEST/xcodegen/bin"
[ -x "$BIN/xcodegen" ] || fail "no xcodegen binary in the zip"
VERSION="$("$BIN/xcodegen" --version 2> /dev/null | sed -n 's/^Version: //p')"
[ "$VERSION" = "$XCODEGEN_VERSION" ] || fail "xcodegen reports version '$VERSION', expected $XCODEGEN_VERSION"
printf '%s\n' "$BIN"
