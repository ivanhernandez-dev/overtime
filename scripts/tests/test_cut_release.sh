#!/bin/bash

new_sandbox
mkdir "$T/realgit"
ln -s "$REAL_GIT" "$T/realgit/git"

FIXTURE_EMAIL="fixture@example.invalid"

fixture_git() {
  "$REAL_GIT" -c user.name=Fixture -c user.email="$FIXTURE_EMAIL" -c commit.gpgsign=false "$@"
}

fixture_changelog() {
  printf '%s\n' "# Changelog" "" "Fixture." "" "## [0.5.0]" "" "### Fixed" "" "- A fixture fix." "" \
    "## [0.4.0]" "" "### Added" "" "- A fixture feature."
}

cut_tree() {
  local dir="$T/cut-$1"
  mkdir -p "$dir/scripts/release/lib" || return 1
  cp "$REPO/scripts/release/cut-release.sh" "$dir/scripts/release/cut-release.sh" || return 1
  cp "$REPO/scripts/release/lib/pipeline.sh" "$dir/scripts/release/lib/pipeline.sh" || return 1
  awk '
    $1 == "MARKETING_VERSION:" { sub(/MARKETING_VERSION:.*/, "MARKETING_VERSION: 0.4.0") }
    $1 == "CURRENT_PROJECT_VERSION:" { sub(/CURRENT_PROJECT_VERSION:.*/, "CURRENT_PROJECT_VERSION: 400") }
    { print }
  ' "$REPO/project.yml" > "$dir/project.yml" || return 1
  fixture_changelog > "$dir/CHANGELOG.md" || return 1
  "$REAL_GIT" -C "$dir" init -q -b main || return 1
  "$REAL_GIT" -C "$dir" add -A || return 1
  fixture_git -C "$dir" commit -q -m "Fixture" || return 1
  "$REAL_GIT" clone -q --bare "$dir" "$T/cut-$1.git" || return 1
  "$REAL_GIT" -C "$dir" remote add origin "$T/cut-$1.git"
}

tree_git() {
  local name="$1"
  shift
  "$REAL_GIT" -C "$T/cut-$name" "$@"
}

recommit() {
  tree_git "$1" add -A && fixture_git -C "$T/cut-$1" commit -q -m "Fixture variant"
}

run_cut() {
  local name="$1"
  shift
  PATH="$T/realgit:$PATH" GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL="$FIXTURE_EMAIL" \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL="$FIXTURE_EMAIL" \
    /bin/bash "$T/cut-$name/scripts/release/cut-release.sh" "$@" > "$T/cut-$name.log" 2>&1
}

cut_state() {
  tree_git "$1" rev-parse HEAD
  tree_git "$1" status --porcelain
  tree_git "$1" tag -l
  shasum -a 256 "$T/cut-$1/project.yml" "$T/cut-$1/CHANGELOG.md"
}

refuses() {
  local name="$1" version="$2" reason="$3" log="$T/cut-$1.log" before status
  before="$(cut_state "$name")" || return 1
  run_cut "$name" --version "$version"
  status=$?
  [ "$status" -eq 1 ] || { printf 'exit %s\n' "$status"; cat "$log"; return 1; }
  [ "$(grep -c '^cut: refused: ' "$log")" -eq 1 ] || { cat "$log"; return 1; }
  grep -qxF "cut: refused: $reason" "$log" || { cat "$log"; return 1; }
  [ "$(cut_state "$name")" = "$before" ] || { printf 'the tree changed\n'; return 1; }
}

setting_of() {
  awk -v key="$2:" '$1 == key { print $2 }' "$T/cut-$1/project.yml"
}

section_between() {
  awk -v from="$2" -v to="$3" '
    index($0, to) == 1 { on = 0 }
    on { print }
    index($0, from) == 1 { on = 1 }
  ' "$1"
}

cut_ok() {
  local status
  cut_tree ok || return 1
  tree_git ok rev-parse HEAD > "$T/ok.fixture" || return 1
  date -u +%Y-%m-%d > "$T/ok.before"
  run_cut ok --version 0.5.0
  status=$?
  date -u +%Y-%m-%d > "$T/ok.after"
  [ "$status" -eq 0 ] || { cat "$T/cut-ok.log"; return 1; }
  [ "$(tree_git ok log -1 --format=%s)" = "Release 0.5.0" ] || return 1
  [ "$(tree_git ok rev-parse HEAD^)" = "$(cat "$T/ok.fixture")" ] || return 1
  [ "$(tree_git ok symbolic-ref --short HEAD)" = "main" ]
}

ok_commit_files() {
  [ "$(tree_git ok diff-tree --no-commit-id --name-only -r HEAD | LC_ALL=C sort)" = "$(printf '%s\n' CHANGELOG.md project.yml)" ]
}

ok_versions() {
  [ "$(setting_of ok MARKETING_VERSION)" = "0.5.0" ] && [ "$(setting_of ok CURRENT_PROJECT_VERSION)" = "500" ] \
    && [ "$(awk '$1 == "MARKETING_VERSION:"' "$T/cut-ok/project.yml" | awk 'END { print NR }')" = "1" ] \
    && [ "$(awk '$1 == "CURRENT_PROJECT_VERSION:"' "$T/cut-ok/project.yml" | awk 'END { print NR }')" = "1" ]
}

ok_heading() {
  local before after file="$T/cut-ok/CHANGELOG.md"
  before="$(cat "$T/ok.before")" || return 1
  after="$(cat "$T/ok.after")" || return 1
  [ "$(grep -c '^## \[0\.5\.0\]' "$file")" -eq 1 ] || return 1
  grep -qxF "## [0.5.0] - $before" "$file" || grep -qxF "## [0.5.0] - $after" "$file" || { grep '^## ' "$file"; return 1; }
  fixture_changelog > "$T/ok.expected" || return 1
  [ "$(section_between "$file" "## [0.5.0]" "## [0.4.0]")" = "$(section_between "$T/ok.expected" "## [0.5.0]" "## [0.4.0]")" ]
}

ok_tag() {
  [ "$(tree_git ok cat-file -t v0.5.0)" = "tag" ] \
    && [ "$(tree_git ok rev-parse "v0.5.0^{commit}")" = "$(tree_git ok rev-parse HEAD)" ]
}

ok_nothing_pushed() {
  tree_git ok rev-parse -q --verify refs/tags/v0.5.0 > /dev/null || return 1
  [ "$("$REAL_GIT" --git-dir "$T/cut-ok.git" rev-parse refs/heads/main)" = "$(cat "$T/ok.fixture")" ] || return 1
  [ -z "$("$REAL_GIT" --git-dir "$T/cut-ok.git" tag -l)" ]
}

ok_no_gh() {
  [ "$(tree_git ok log -1 --format=%s)" = "Release 0.5.0" ] && no_shim_calls gh
}

cut_current_version() {
  local status file="$T/cut-current/CHANGELOG.md"
  cut_tree current || return 1
  run_cut current --version 0.4.0
  status=$?
  [ "$status" -eq 0 ] || { cat "$T/cut-current.log"; return 1; }
  [ "$(tree_git current diff-tree --no-commit-id --name-only -r HEAD)" = "CHANGELOG.md" ] || return 1
  [ "$(setting_of current MARKETING_VERSION)" = "0.4.0" ] || return 1
  [ "$(setting_of current CURRENT_PROJECT_VERSION)" = "400" ] || return 1
  grep -qE '^## \[0\.4\.0\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$file"
}

refuses_invalid_versions() {
  local version
  cut_tree invalid || return 1
  for version in 0.5 0.100.0 v0.5.0 0.5.0-rc1 05.0.0; do
    refuses invalid "$version" \
      "invalid version $version (expected X.Y.Z, each part 0 to 99 with no leading zero)" || return 1
  done
}

refuses_off_main() {
  cut_tree feature && tree_git feature checkout -q -b feature \
    && refuses feature 0.5.0 "not on main (on feature)"
}

refuses_dirty_tree() {
  cut_tree dirty && printf '\n' >> "$T/cut-dirty/project.yml" \
    && refuses dirty 0.5.0 "the working tree has uncommitted changes"
}

refuses_local_tag() {
  cut_tree localtag && tree_git localtag tag v0.5.0 \
    && refuses localtag 0.5.0 "tag v0.5.0 already exists"
}

refuses_origin_tag() {
  cut_tree origintag && "$REAL_GIT" --git-dir "$T/cut-origintag.git" tag v0.5.0 main \
    && refuses origintag 0.5.0 "tag v0.5.0 already exists on origin"
}

refuses_unreadable_origin() {
  cut_tree noorigin && tree_git noorigin remote set-url origin "$T/missing-origin.git" \
    && refuses noorigin 0.5.0 "could not read the tags of origin"
}

refuses_lower_version() {
  cut_tree lower && refuses lower 0.3.9 "0.3.9 is lower than MARKETING_VERSION 0.4.0"
}

refuses_missing_heading() {
  cut_tree noheading && refuses noheading 0.6.0 "CHANGELOG.md has no ## [0.6.0] heading"
}

refuses_empty_section() {
  cut_tree empty || return 1
  printf '%s\n' "# Changelog" "" "Fixture." "" "## [0.5.0]" "" "## [0.4.0]" "" "### Added" "" \
    "- A fixture feature." > "$T/cut-empty/CHANGELOG.md" || return 1
  recommit empty && refuses empty 0.5.0 "the ## [0.5.0] section of CHANGELOG.md is empty"
}

refuses_dated_heading() {
  cut_tree dated || return 1
  fixture_changelog | sed 's/^## \[0\.5\.0\]$/## [0.5.0] - 2026-10-01/' > "$T/cut-dated/CHANGELOG.md" || return 1
  recommit dated && refuses dated 0.5.0 "the ## [0.5.0] heading in CHANGELOG.md is already dated"
}

refuses_two_headings() {
  cut_tree twoheadings || return 1
  printf '%s\n' "" "## [0.5.0]" "" "- Another fixture fix." >> "$T/cut-twoheadings/CHANGELOG.md" || return 1
  recommit twoheadings && refuses twoheadings 0.5.0 "CHANGELOG.md has 2 ## [0.5.0] headings"
}

refuses_two_marketing_lines() {
  cut_tree twoversions || return 1
  printf '%s\n' "        MARKETING_VERSION: 0.4.0" >> "$T/cut-twoversions/project.yml" || return 1
  recommit twoversions && refuses twoversions 0.5.0 "project.yml has 2 MARKETING_VERSION lines"
}

usage_exits_64() {
  local name="$1" status
  shift
  cut_tree "$name" || return 1
  run_cut "$name" "$@"
  status=$?
  [ "$status" -eq 64 ] || { printf 'exit %s\n' "$status"; cat "$T/cut-$name.log"; return 1; }
}

script_shape() {
  [ "$(head -1 "$REPO/scripts/release/cut-release.sh")" = "#!/bin/bash" ] \
    && /bin/bash -n "$REPO/scripts/release/cut-release.sh"
}

check "cut 0.5.0 from 0.4.0 commits Release 0.5.0 on main" cut_ok
check "the release commit changes only project.yml and CHANGELOG.md" ok_commit_files
check "project.yml then carries MARKETING_VERSION 0.5.0 and CURRENT_PROJECT_VERSION 500" ok_versions
check "the 0.5.0 heading carries the UTC date of the run and its notes are unchanged" ok_heading
check "v0.5.0 is an annotated tag on the release commit" ok_tag
check "the cut tags locally and pushes nothing: origin keeps its main and has no v0.5.0" ok_nothing_pushed
check "the successful cut makes no gh call" ok_no_gh
check "cutting the current version 0.4.0 dates its heading and leaves project.yml unchanged" cut_current_version
check "invalid versions are refused before any change" refuses_invalid_versions
check "a cut off main is refused" refuses_off_main
check "a cut with uncommitted changes is refused" refuses_dirty_tree
check "a version whose tag exists locally is refused" refuses_local_tag
check "a version whose tag exists only on origin is refused" refuses_origin_tag
check "a cut that cannot read the tags of origin is refused" refuses_unreadable_origin
check "a version lower than MARKETING_VERSION is refused" refuses_lower_version
check "a version with no CHANGELOG heading is refused" refuses_missing_heading
check "a version with an empty CHANGELOG section is refused" refuses_empty_section
check "a version whose heading is already dated is refused" refuses_dated_heading
check "a version with two CHANGELOG headings is refused" refuses_two_headings
check "a project.yml with two MARKETING_VERSION lines is refused" refuses_two_marketing_lines
check "cut-release.sh without --version exits 64" usage_exits_64 nousage
check "cut-release.sh with an unknown flag exits 64" usage_exits_64 badflag --version 0.5.0 --push
check "cut-release.sh starts with #!/bin/bash and parses under /bin/bash" script_shape
