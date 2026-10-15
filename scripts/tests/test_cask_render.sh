#!/bin/bash

new_sandbox

TEMPLATE="$REPO/packaging/homebrew/overtime.rb.template"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
CASK="$T/out/Casks/overtime.rb"
RENDER_LOG="$T/render.log"

render() {
  (
    . "$REPO/scripts/release/lib/pipeline.sh"
    . "$REPO/scripts/release/lib/cask.sh"
    ot_render_cask "$@"
  )
}

refused() {
  local out="$T/refused-$1.rb"
  shift
  if render "$TEMPLATE" "$@" "$out" > "$RENDER_LOG" 2>&1; then
    cat "$RENDER_LOG"
    return 1
  fi
  [ ! -e "$out" ] && grep -q '^release: error: ' "$RENDER_LOG"
}

has_line() {
  grep -qxF -- "$1" "$CASK" || { printf 'missing line: %s\n' "$1"; return 1; }
}

trimmed() {
  sed 's/^[[:space:]]*//' "$CASK"
}

line_number() {
  trimmed | grep -nF -m1 -- "$1" | cut -d: -f1
}

one_uninstall_line_that_only_quits() {
  local lines
  lines="$(trimmed | grep '^uninstall')"
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = "1" ] \
    && [ "$lines" = 'uninstall quit: "io.github.ivanhernandez-dev.overtime"' ] \
    || { printf 'uninstall lines: %s\n' "$lines"; return 1; }
}

zap_items() {
  awk -v key="$1:" '
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/^zap /, "", line) }
    index(line, key) == 1 { inside = 1 }
    inside && /"/ { n = split($0, parts, "\""); for (i = 2; i < n; i += 2) print parts[i] }
    inside && /\]/ { exit }
  ' "$CASK"
}

zap_runs_bundled_script() {
  has_line '        executable: "Overtime.app/Contents/Resources/uninstall.sh",' \
    && has_line '        args:       ["--purge", "--app-absent"],'
}

trash_and_delete_counts() {
  [ "$(zap_items trash | wc -l | tr -d ' ')" = "7" ] && [ "$(zap_items delete | wc -l | tr -d ' ')" = "2" ] \
    && [ "$(zap_items delete | tr '\n' '|')" = "/Library/Application Support/Overtime|/Library/Logs/Overtime|" ]
}

zap_keys_in_homebrew_order() {
  local launchctl script delete trash
  launchctl="$(line_number 'zap launchctl:')"
  script="$(line_number 'script:')"
  delete="$(line_number 'delete:')"
  trash="$(line_number 'trash:')"
  [ -n "$launchctl" ] && [ -n "$script" ] && [ -n "$delete" ] && [ -n "$trash" ] \
    && [ "$launchctl" -lt "$script" ] && [ "$script" -lt "$delete" ] && [ "$delete" -lt "$trash" ]
}

zap_arrays_alphabetical() {
  local key
  for key in trash delete; do
    [ "$(zap_items "$key")" = "$(zap_items "$key" | LC_ALL=C sort -f)" ] || { printf '%s is not sorted\n' "$key"; return 1; }
  done
}

auto_updates_before_depends_on() {
  local auto depends
  auto="$(line_number 'auto_updates true')"
  depends="$(line_number 'depends_on arch:')"
  [ -n "$auto" ] && [ -n "$depends" ] && [ "$auto" -lt "$depends" ]
}

ruby_syntax_ok() {
  [ "$(ruby -c "$CASK")" = "Syntax OK" ]
}

caveats_are_gui_only() {
  grep -qF 'Privacy & Security > Open Anyway' "$CASK" && grep -qF 'Control-click Overtime in Applications' "$CASK" \
    && ! grep -qiE 'xattr|quarantine' "$CASK"
}

desc_follows_homebrew_rules() {
  local desc
  desc="$(sed -n 's/^  desc "\(.*\)"$/\1/p' "$CASK")"
  [ -n "$desc" ] && [ "${#desc}" -lt 80 ] && [ "${desc%.}" = "$desc" ] \
    && ! printf '%s\n' "$desc" | grep -qiE '(^|[^a-z])(mac|os ?x)' && ! printf '%s\n' "$desc" | grep -qiE '^(the|an?) '
}

render "$TEMPLATE" 1.2.3 "$SHA" "$CASK" > "$RENDER_LOG" 2>&1
RENDER_STATUS=$?
[ "$RENDER_STATUS" -eq 0 ] || sed 's/^/      > /' "$RENDER_LOG"

check "rendering 1.2.3 with a 64-hex SHA writes the cask" eval '[ "$RENDER_STATUS" -eq 0 ] && [ -s "$CASK" ]'
check "the cask has version 1.2.3" has_line '  version "1.2.3"'
check "the cask has the zip SHA-256" has_line "  sha256 \"$SHA\""
check "the url keeps #{version}" \
  has_line '  url "https://github.com/ivanhernandez-dev/overtime/releases/download/v#{version}/Overtime-#{version}.zip"'
check "depends_on arch: :arm64 and macos: :sonoma" \
  eval 'has_line "  depends_on arch: :arm64" && has_line "  depends_on macos: :sonoma"'
check "auto_updates true comes before depends_on" eval 'has_line "  auto_updates true" && auto_updates_before_depends_on'
check "the cask installs Overtime.app" has_line '  app "Overtime.app"'
check "exactly one uninstall line, and it only quits the app" one_uninstall_line_that_only_quits
check "zap boots out the helper label" has_line '  zap launchctl: "io.github.ivanhernandez-dev.overtime.helper",'
check "zap runs the bundled uninstall.sh with --purge and --app-absent" zap_runs_bundled_script
check "zap trashes seven paths and deletes the two /Library folders" trash_and_delete_counts
check "zap keys follow Homebrew's order and its arrays are alphabetical" \
  eval 'zap_keys_in_homebrew_order && zap_arrays_alphabetical'
check "the caveats give the GUI Gatekeeper steps and no quarantine recipe" caveats_are_gui_only
check "the desc follows Homebrew's description rules" desc_follows_homebrew_rules
check "ruby -c prints Syntax OK" ruby_syntax_ok
check "no {{ placeholder remains" eval '! grep -qF "{{" "$CASK"'
check "a 63-character SHA is refused" refused short 1.2.3 "${SHA%?}"
check "an uppercase SHA is refused" refused upper 1.2.3 "$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
check "a non-hex SHA is refused" refused nonhex 1.2.3 "${SHA%?}g"
check "version 1.2 is refused" refused version 1.2 "$SHA"
check "no brew call was made" no_shim_calls brew
