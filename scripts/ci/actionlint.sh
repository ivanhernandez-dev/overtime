#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  printf 'usage: actionlint.sh [--tarball FILE]\n' >&2
  exit 64
}

fail() {
  printf 'actionlint: %s\n' "$1" >&2
  exit 1
}

TARBALL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$TARBALL" ] || usage
      TARBALL="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

. "$REPO/scripts/release/pins.env"

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/actionlint.XXXXXX")"
cleanup() {
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

if [ -z "$TARBALL" ]; then
  TARBALL="$WORK/actionlint.tar.gz"
  curl -fsSL --retry 3 -o "$TARBALL" \
    "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz" \
    || fail "downloading actionlint $ACTIONLINT_VERSION failed"
fi
[ -f "$TARBALL" ] || fail "no tarball at $TARBALL"

DIGEST="$(shasum -a 256 "$TARBALL" | awk '{ print $1 }')"
[ "$DIGEST" = "$ACTIONLINT_DARWIN_ARM64_SHA256" ] \
  || fail "tarball digest $DIGEST differs from the pinned $ACTIONLINT_DARWIN_ARM64_SHA256; nothing extracted"

mkdir "$WORK/bin"
tar -xzf "$TARBALL" -C "$WORK/bin" actionlint || fail "extracting actionlint failed"
[ "$("$WORK/bin/actionlint" -version 2> /dev/null | head -1)" = "$ACTIONLINT_VERSION" ] \
  || fail "the extracted actionlint is not version $ACTIONLINT_VERSION"

cd "$REPO"
STATUS=0
"$WORK/bin/actionlint" -shellcheck= -pyflakes= .github/workflows/*.yml || STATUS=$?
exit "$STATUS"
