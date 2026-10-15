#!/bin/bash
set -euo pipefail

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$RELEASE_DIR/lib/pipeline.sh"

usage() {
  printf 'usage: cut-release.sh --version X.Y.Z\n' >&2
  exit 64
}

refuse() {
  printf 'cut: refused: %s\n' "$1" >&2
  exit 1
}

fail() {
  printf 'cut: failed: %s\n' "$1" >&2
  exit 1
}

VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$VERSION" ] || usage
      VERSION="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[ -n "$VERSION" ] || usage

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cut-release.XXXXXX")"
cleanup() {
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

PROJECT="$REPO/project.yml"
CHANGELOG="$REPO/CHANGELOG.md"
HEADING="## [$VERSION]"

BUILD="$(ot_build_number "$VERSION" 2> /dev/null)" \
  || refuse "invalid version $VERSION (expected X.Y.Z, each part 0 to 99 with no leading zero)"

BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD || true)"
if [ -z "$BRANCH" ]; then
  refuse "not on main (on a detached HEAD)"
elif [ "$BRANCH" != "main" ]; then
  refuse "not on main (on $BRANCH)"
fi

CHANGES="$(git -C "$REPO" status --porcelain --untracked-files=no)" || refuse "git status failed"
[ -z "$CHANGES" ] || refuse "the working tree has uncommitted changes"

for KEY in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
  COUNT="$(awk -v key="$KEY:" '$1 == key { n++ } END { print n + 0 }' "$PROJECT")" \
    || refuse "project.yml cannot be read"
  [ "$COUNT" = "1" ] || refuse "project.yml has $COUNT $KEY lines"
done

CURRENT="$(ot_marketing_version)"
CURRENT_BUILD="$(ot_build_number "$CURRENT" 2> /dev/null)" \
  || refuse "project.yml MARKETING_VERSION $CURRENT is not X.Y.Z"
[ "$BUILD" -ge "$CURRENT_BUILD" ] || refuse "$VERSION is lower than MARKETING_VERSION $CURRENT"

if git -C "$REPO" rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
  refuse "tag v$VERSION already exists"
fi

REMOTE_STATUS=0
git -C "$REPO" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null 2>&1 || REMOTE_STATUS=$?
case "$REMOTE_STATUS" in
  2) ;;
  0) refuse "tag v$VERSION already exists on origin" ;;
  *) refuse "could not read the tags of origin" ;;
esac

COUNT="$(awk -v heading="$HEADING" '$0 == heading || index($0, heading " ") == 1 { n++ } END { print n + 0 }' \
  "$CHANGELOG")" || refuse "CHANGELOG.md cannot be read"
[ "$COUNT" != "0" ] || refuse "CHANGELOG.md has no $HEADING heading"
[ "$COUNT" = "1" ] || refuse "CHANGELOG.md has $COUNT $HEADING headings"
grep -qxF "$HEADING" "$CHANGELOG" || refuse "the $HEADING heading in CHANGELOG.md is already dated"

mkdir "$WORK/before" "$WORK/after"
ot_notes "$WORK/before" "$VERSION" 2> /dev/null || refuse "the $HEADING section of CHANGELOG.md is empty"

DATE="$(date -u +%Y-%m-%d)"
DATED="$HEADING - $DATE"
awk -v version="$VERSION" -v build="$BUILD" '
  $1 == "MARKETING_VERSION:" { sub(/MARKETING_VERSION:.*/, "MARKETING_VERSION: " version) }
  $1 == "CURRENT_PROJECT_VERSION:" { sub(/CURRENT_PROJECT_VERSION:.*/, "CURRENT_PROJECT_VERSION: " build) }
  { print }
' "$PROJECT" > "$WORK/project.yml" || fail "preparing the project.yml edit failed; nothing was changed"
awk -v heading="$HEADING" -v dated="$DATED" '$0 == heading { print dated; next } { print }' \
  "$CHANGELOG" > "$WORK/CHANGELOG.md" || fail "preparing the CHANGELOG.md edit failed; nothing was changed"

restore() {
  git -C "$REPO" checkout -q HEAD -- project.yml CHANGELOG.md
}

edit_verified() {
  cat "$WORK/project.yml" > "$PROJECT" && cat "$WORK/CHANGELOG.md" > "$CHANGELOG" || return 1
  ot_check_release_version "$VERSION" "$(ot_marketing_version)" "$(ot_project_build)" 2> /dev/null || return 1
  ot_notes "$WORK/after" "$VERSION" 2> /dev/null || return 1
  cmp -s "$WORK/before/notes-$VERSION.md" "$WORK/after/notes-$VERSION.md" || return 1
  [ "$(awk -v dated="$DATED" '$0 == dated { n++ } END { print n + 0 }' "$CHANGELOG")" = "1" ]
}

if ! edit_verified; then
  restore || fail "the edit did not verify, and project.yml and CHANGELOG.md could not be restored"
  fail "the edit did not verify; project.yml and CHANGELOG.md were restored"
fi

if ! git -C "$REPO" commit -q -m "Release $VERSION" -- project.yml CHANGELOG.md; then
  restore || fail "git commit failed, and project.yml and CHANGELOG.md could not be restored"
  fail "git commit failed; project.yml and CHANGELOG.md were restored"
fi

git -C "$REPO" tag -a "v$VERSION" -m "Overtime $VERSION" || fail "tagging failed; the commit Release $VERSION is local only"

printf 'cut: committed Release %s\n' "$VERSION"
printf 'cut: tagged v%s\n' "$VERSION"
printf 'cut: nothing was pushed\n'
