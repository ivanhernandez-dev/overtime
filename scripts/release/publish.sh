#!/bin/bash
set -euo pipefail

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$RELEASE_DIR/lib/pipeline.sh"

usage() {
  printf 'usage: publish.sh --from DIR\n' >&2
  exit 64
}

refuse() {
  printf 'publish: refused: %s\n' "$1" >&2
  exit 1
}

stop() {
  printf 'publish: failed: %s\n' "$1" >&2
  exit 1
}

FROM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$FROM" ] || usage
      FROM="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[ -n "$FROM" ] || usage

ot_load_pins

[ "${CI:-}" = "true" ] || refuse "publishing runs only in CI (CI is not true)"

REF="${GITHUB_REF:-}"
case "$REF" in
  refs/tags/v*) ;;
  *) refuse "GITHUB_REF is not a v* tag" ;;
esac
VERSION="${REF#refs/tags/v}"
ot_build_number "$VERSION" > /dev/null 2>&1 || refuse "the tag is not vX.Y.Z"
MARKETING="$(ot_marketing_version)"
[ "$VERSION" = "$MARKETING" ] || refuse "tag v$VERSION differs from MARKETING_VERSION $MARKETING"
TAG="v$VERSION"

COMMIT="${GITHUB_SHA:-}"
COMMIT_PATTERN='^[0-9a-f]{40}$'
[[ "$COMMIT" =~ $COMMIT_PATTERN ]] || refuse "GITHUB_SHA is not a commit id"
(cd "$REPO" && git merge-base --is-ancestor "$COMMIT" origin/main) > /dev/null 2>&1 \
  || refuse "commit $COMMIT is not on origin/main"

[ -d "$FROM" ] && [ ! -L "$FROM" ] || refuse "--from is not a folder"
FROM="$(cd "$FROM" && pwd)"
DIST="$FROM/dist"
DMG="Overtime-$VERSION.dmg"
ZIP="Overtime-$VERSION.zip"
NOTES="$FROM/notes-$VERSION.md"
CASK="$FROM/Casks/overtime.rb"
for asset in "$DIST/$DMG" "$DIST/$ZIP" "$DIST/appcast.xml" "$DIST/SHA256SUMS" "$NOTES" "$CASK"; do
  [ -f "$asset" ] && [ ! -L "$asset" ] && [ -s "$asset" ] || refuse "missing ${asset#"$FROM"/}"
done
LISTED="$(awk '{ print $2 }' "$DIST/SHA256SUMS" | sort | tr '\n' ' ')"
EXPECTED="$(printf '%s\n' "$DMG" "$ZIP" appcast.xml | sort | tr '\n' ' ')"
[ "$LISTED" = "$EXPECTED" ] || refuse "SHA256SUMS does not list exactly the DMG, the zip and appcast.xml"
(cd "$DIST" && shasum -a 256 -c SHA256SUMS) > /dev/null 2>&1 || refuse "SHA256SUMS does not match the assets"
ZIP_SHA256="$(awk -v name="$ZIP" '$2 == name { print $1 }' "$DIST/SHA256SUMS")"
CASK_LINES="$(sed 's/^[[:space:]]*//' "$CASK")"
printf '%s\n' "$CASK_LINES" | grep -qxF "version \"$VERSION\"" || refuse "the cask is not for version $VERSION"
printf '%s\n' "$CASK_LINES" | grep -qxF "sha256 \"$ZIP_SHA256\"" || refuse "the cask's sha256 is not the zip's"

[ -n "${GH_TOKEN:-}" ] || refuse "GH_TOKEN is not set"
[ -n "${HOMEBREW_TAP_TOKEN:-}" ] || refuse "HOMEBREW_TAP_TOKEN is not set"
TAP_PATTERN='^[A-Za-z0-9-]+/homebrew-[A-Za-z0-9-]+$'
[[ "${TAP_REPOSITORY:-}" =~ $TAP_PATTERN ]] || refuse "TAP_REPOSITORY in pins.env is not owner/homebrew-name"
TAP_FILE="repos/$TAP_REPOSITORY/contents/Casks/overtime.rb"

cd "$REPO"

gh release create "$TAG" --draft --verify-tag --title "Overtime $VERSION" --notes-file "$NOTES" > /dev/null \
  || stop "creating the draft release failed; nothing was published"
printf 'publish: draft created\n'

gh release upload "$TAG" "$DIST/$DMG" "$DIST/$ZIP" "$DIST/appcast.xml" "$DIST/SHA256SUMS" > /dev/null \
  || stop "uploading the assets failed; the release stays a draft and the tap is untouched"
printf 'publish: assets uploaded\n'

gh release edit "$TAG" --draft=false --latest > /dev/null \
  || stop "publishing the draft failed; the release stays a draft and the tap is untouched"
printf 'publish: published as latest\n'

CURRENT_SHA=""
if READ_SHA="$(GH_TOKEN="$HOMEBREW_TAP_TOKEN" gh api "$TAP_FILE" --jq .sha 2> /dev/null)"; then
  BLOB_PATTERN='^[0-9a-f]{40}$'
  if [[ "$READ_SHA" =~ $BLOB_PATTERN ]]; then
    CURRENT_SHA="$READ_SHA"
  fi
fi
CONTENT="$(base64 < "$CASK" | tr -d '\n')"
PUT=(api -X PUT "$TAP_FILE" -f "message=overtime $VERSION" -f "content=$CONTENT")
if [ -n "$CURRENT_SHA" ]; then
  PUT+=(-f "sha=$CURRENT_SHA")
fi
GH_TOKEN="$HOMEBREW_TAP_TOKEN" gh "${PUT[@]}" > /dev/null \
  || stop "updating the tap failed; release $TAG is published and the tap still has the previous cask"
printf 'publish: tap updated\n'
