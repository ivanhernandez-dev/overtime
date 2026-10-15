#!/bin/bash

new_sandbox
ln -s "$REPO/scripts/tests/shim.sh" "$T/bin/curl"
mkdir "$T/libexec"
ln -s "$REPO/scripts/tests/shim.sh" "$T/libexec/gh"
printf '%s\n' \
  '#!/bin/bash' \
  'who=other' \
  'case "${GH_TOKEN:-}" in' \
  '  "$FAKE_RELEASE_TOKEN") who=release ;;' \
  '  "$FAKE_TAP_TOKEN") who=tap ;;' \
  'esac' \
  'printf "%s\t%s\n" "${1:-}" "$who" >> "$T/tokens.log"' \
  'exec "$T/libexec/gh" "$@"' > "$T/gh-wrapper"
chmod 755 "$T/gh-wrapper"
mv -f "$T/gh-wrapper" "$T/bin/gh"

FAKE_RELEASE_TOKEN="fake-release-token-value-7f3a"
FAKE_TAP_TOKEN="fake-tap-token-value-91c2"
FAKE_COMMIT="1111111111111111111111111111111111111111"
CURRENT_BLOB="2222222222222222222222222222222222222222"
export FAKE_RELEASE_TOKEN FAKE_TAP_TOKEN

V="$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' "$REPO/project.yml")"
if [ "$V" = "0.1.1" ]; then OTHER="0.1.2"; else OTHER="0.1.1"; fi
TAP_FILE="repos/ivanhernandez-dev/homebrew-tap/contents/Casks/overtime.rb"
PUBLISH_LOG="$T/publish.log"

make_from() {
  local from="$1" sha
  mkdir -p "$from/dist" "$from/Casks"
  head -c 4096 /dev/urandom > "$from/dist/Overtime-$V.dmg"
  head -c 4096 /dev/urandom > "$from/dist/Overtime-$V.zip"
  printf '<rss><channel><item/></channel></rss>\n' > "$from/dist/appcast.xml"
  (cd "$from/dist" && shasum -a 256 "Overtime-$V.dmg" "Overtime-$V.zip" appcast.xml > SHA256SUMS)
  printf '### Added\n\n- Everything.\n' > "$from/notes-$V.md"
  sha="$(shasum -a 256 "$from/dist/Overtime-$V.zip" | awk '{ print $1 }')"
  printf 'cask "overtime" do\n  version "%s"\n  sha256 "%s"\nend\n' "$V" "$sha" > "$from/Casks/overtime.rb"
}

FROM="$T/from"
make_from "$FROM"
FROM="$(cd "$FROM" && pwd)"

MERGE_BASE_CODE=0

reset_shims() {
  find "$SHIM_DIR" -name 'gh.*' -delete
  find "$SHIM_DIR" -name 'git.*' -delete
  : > "$SHIM_LOG"
  : > "$T/tokens.log"
  shim_allow_sub git merge-base "$MERGE_BASE_CODE"
}

allow_gh() {
  shim_allow_sub gh release 0
  shim_allow_sub gh api 0 "$CURRENT_BLOB"
}

publish() {
  local dropped=" " pair
  local pairs=()
  while [ "${1:-}" = "-u" ]; do
    dropped="$dropped$2 "
    shift 2
  done
  for pair in CI=true "GITHUB_REF=refs/tags/v$V" "GITHUB_SHA=$FAKE_COMMIT" "GH_TOKEN=$FAKE_RELEASE_TOKEN" \
    "HOMEBREW_TAP_TOKEN=$FAKE_TAP_TOKEN"; do
    case "$dropped" in
      *" ${pair%%=*} "*) ;;
      *) pairs+=("$pair") ;;
    esac
  done
  env -u CI -u GITHUB_REF -u GITHUB_SHA -u GH_TOKEN -u HOMEBREW_TAP_TOKEN -u GITHUB_TOKEN -u GH_REPO \
    "${pairs[@]}" "$@" > "$PUBLISH_LOG" 2>&1
}

refuses_not_on_main() {
  local result=0
  MERGE_BASE_CODE=1
  refuses "is not on origin/main" || result=1
  MERGE_BASE_CODE=0
  return "$result"
}

run_publish() {
  publish "$@" /bin/bash "$REPO/scripts/release/publish.sh" --from "$FROM"
}

refuses() {
  local reason="$1" status
  shift
  reset_shims
  allow_gh
  run_publish "$@"
  status=$?
  [ "$status" -eq 1 ] && [ "$(grep -c '^publish: ' "$PUBLISH_LOG")" = "1" ] \
    && grep '^publish: refused: ' "$PUBLISH_LOG" | grep -qF -- "$reason" && [ -z "$(shim_calls gh)" ] \
    || { printf 'exit %s, expected reason: %s\n' "$status" "$reason"; cat "$PUBLISH_LOG"; shim_calls gh; return 1; }
}

refuses_with_from() {
  local saved="$FROM" result=0
  FROM="$1"
  shift
  refuses "$@" || result=1
  FROM="$saved"
  return "$result"
}

expected_happy_calls() {
  printf '%s\n' \
    "release create v$V --draft --verify-tag --title Overtime $V --notes-file $FROM/notes-$V.md" \
    "release upload v$V $FROM/dist/Overtime-$V.dmg $FROM/dist/Overtime-$V.zip $FROM/dist/appcast.xml $FROM/dist/SHA256SUMS" \
    "release edit v$V --draft=false --latest" \
    "api $TAP_FILE --jq .sha" \
    "api -X PUT $TAP_FILE -f message=overtime $V -f content=$(base64 < "$FROM/Casks/overtime.rb" | tr -d '\n') -f sha=$CURRENT_BLOB"
}

happy_run() {
  reset_shims
  allow_gh
  run_publish || { cat "$PUBLISH_LOG"; return 1; }
}

happy_path_calls_gh_in_order_and_nothing_else() {
  happy_run || return 1
  [ "$(shim_calls gh)" = "$(expected_happy_calls)" ] || {
    printf 'calls:\n%s\nexpected:\n%s\n' "$(shim_calls gh)" "$(expected_happy_calls)"
    return 1
  }
}

happy_path_uploads_exactly_the_four_assets() {
  local upload
  happy_run || return 1
  upload="$(shim_calls gh | grep '^release upload ')"
  [ "$(printf '%s\n' "$upload" | wc -l | tr -d ' ')" = "1" ] \
    && [ "$upload" = "release upload v$V $FROM/dist/Overtime-$V.dmg $FROM/dist/Overtime-$V.zip $FROM/dist/appcast.xml $FROM/dist/SHA256SUMS" ]
}

happy_path_prints_the_steps_in_order() {
  happy_run || return 1
  [ "$(cat "$PUBLISH_LOG")" = "$(printf '%s\n' 'publish: draft created' 'publish: assets uploaded' \
    'publish: published as latest' 'publish: tap updated')" ] || { cat "$PUBLISH_LOG"; return 1; }
}

release_calls_use_the_release_token_and_tap_calls_the_tap_token() {
  happy_run || return 1
  [ "$(cat "$T/tokens.log")" = "$(printf 'release\trelease\nrelease\trelease\nrelease\trelease\napi\ttap\napi\ttap\n')" ] \
    || { cat "$T/tokens.log"; return 1; }
}

tokens_never_appear_in_output_or_arguments() {
  happy_run || return 1
  ! grep -qF -e "$FAKE_RELEASE_TOKEN" -e "$FAKE_TAP_TOKEN" "$PUBLISH_LOG" "$SHIM_LOG"
}

no_curl_brew_or_git_write() {
  happy_run || return 1
  no_shim_calls curl brew && [ "$(shim_calls git)" = "merge-base --is-ancestor $FAKE_COMMIT origin/main" ]
}

missing_tap_file_puts_without_sha() {
  reset_shims
  shim_allow_sub gh release 0
  shim_allow_sub gh api 1
  shim_allow_sub2 gh api -X 0
  run_publish || { cat "$PUBLISH_LOG"; return 1; }
  shim_calls gh | grep -q '^api -X PUT ' && ! shim_calls gh | grep -q ' -f sha='
}

shim_allow_sub2() {
  printf '%s\n' "${4:-0}" > "$SHIM_DIR/$1.$2.$3.code"
  printf '%s' "${5:-}" > "$SHIM_DIR/$1.$2.$3.out"
}

fails_at() {
  local status
  reset_shims
  allow_gh
  shim_allow_sub2 gh "$1" "$2" 1
  run_publish
  status=$?
  [ "$status" -eq 1 ] && grep -q '^publish: failed: ' "$PUBLISH_LOG" || { printf 'exit %s\n' "$status"; cat "$PUBLISH_LOG"; return 1; }
}

upload_failure_stops_before_edit_and_tap() {
  fails_at release upload || return 1
  ! shim_calls gh | grep -q '^release edit ' && ! shim_calls gh | grep -q '^api ' \
    && ! grep -q 'publish: assets uploaded' "$PUBLISH_LOG"
}

edit_failure_stops_before_the_tap() {
  fails_at release edit || return 1
  ! shim_calls gh | grep -q '^api ' && ! grep -q 'publish: published as latest' "$PUBLISH_LOG"
}

create_failure_stops_before_upload() {
  fails_at release create || return 1
  [ "$(shim_calls gh | wc -l | tr -d ' ')" = "1" ]
}

put_failure_exits_one() {
  fails_at api -X || return 1
  ! grep -q 'publish: tap updated' "$PUBLISH_LOG" && shim_calls gh | grep -q '^release edit '
}

usage_without_from() {
  reset_shims
  publish /bin/bash "$REPO/scripts/release/publish.sh"
  [ "$?" -eq 64 ] && [ -z "$(shim_calls gh)" ]
}

corrupt_one_byte() {
  local file="$1" first
  first="$(head -c 1 "$file" | od -An -tu1 | tr -d ' ')"
  if [ "$first" = "65" ]; then
    printf 'B' | dd of="$file" bs=1 seek=0 conv=notrunc 2> /dev/null
  else
    printf 'A' | dd of="$file" bs=1 seek=0 conv=notrunc 2> /dev/null
  fi
}

MISSING="$T/missing"
make_from "$MISSING"
rm -f "$MISSING/dist/appcast.xml"
CHANGED="$T/changed"
make_from "$CHANGED"
corrupt_one_byte "$CHANGED/dist/Overtime-$V.zip"
WRONG_CASK="$T/wrong-cask"
make_from "$WRONG_CASK"
printf 'cask "overtime" do\n  version "%s"\n  sha256 "%s"\nend\n' "$V" \
  "0000000000000000000000000000000000000000000000000000000000000000" > "$WRONG_CASK/Casks/overtime.rb"

check "outside CI on a valid tag: refused before any gh call" refuses "only in CI" -u CI
check "CI=1 instead of true: refused" refuses "only in CI" CI=1
check "a branch ref: refused" refuses "not a v* tag" GITHUB_REF=refs/heads/main
check "tag v$OTHER differs from MARKETING_VERSION: refused" refuses "differs from MARKETING_VERSION" \
  GITHUB_REF="refs/tags/v$OTHER"
check "tag v1.2 is not X.Y.Z: refused" refuses "not vX.Y.Z" GITHUB_REF=refs/tags/v1.2
check "no GITHUB_SHA: refused" refuses "GITHUB_SHA" -u GITHUB_SHA
check "a commit that is not on origin/main: refused" refuses_not_on_main
check "a missing asset: refused" refuses_with_from "$MISSING" "missing dist/appcast.xml"
check "one changed byte in the zip fails SHA256SUMS: refused" refuses_with_from "$CHANGED" "does not match"
check "a cask whose sha256 is not the zip's: refused" refuses_with_from "$WRONG_CASK" "sha256 is not the zip"
check "no HOMEBREW_TAP_TOKEN: refused" refuses "HOMEBREW_TAP_TOKEN" -u HOMEBREW_TAP_TOKEN
check "an empty GH_TOKEN: refused" refuses "GH_TOKEN" GH_TOKEN=
check "no --from: usage exit 64" usage_without_from
check "happy path: draft, upload, latest, tap read, tap write, nothing else" happy_path_calls_gh_in_order_and_nothing_else
check "happy path: exactly the DMG, the zip, appcast.xml and SHA256SUMS are uploaded" happy_path_uploads_exactly_the_four_assets
check "happy path: the four step lines in order" happy_path_prints_the_steps_in_order
check "release calls carry the release token, tap calls the tap token" release_calls_use_the_release_token_and_tap_calls_the_tap_token
check "no token value in the output or on any command line" tokens_never_appear_in_output_or_arguments
check "no curl, no brew, and git only for the ancestry check" no_curl_brew_or_git_write
check "no tap file yet: the PUT carries no sha" missing_tap_file_puts_without_sha
check "a failed create stops before the upload" create_failure_stops_before_upload
check "a failed upload stops before the edit and the tap" upload_failure_stops_before_edit_and_tap
check "a failed edit stops before the tap" edit_failure_stops_before_the_tap
check "a failed tap PUT exits 1" put_failure_exits_one
