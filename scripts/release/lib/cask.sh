#!/bin/bash
set -euo pipefail

ot_zip_sha256() {
  local out="$1" version="$2" sha
  sha="$(awk -v name="Overtime-$version.zip" '$2 == name { print $1 }' "$out/dist/SHA256SUMS" 2> /dev/null || true)"
  [ -n "$sha" ] || ot_fail "no Overtime-$version.zip line in $out/dist/SHA256SUMS" || return 1
  printf '%s\n' "$sha"
}

ot_render_cask() {
  local template="$1" version="$2" sha="$3" outfile="$4" rendered syntax
  local sha_pattern='^[0-9a-f]{64}$'
  ot_build_number "$version" > /dev/null || return 1
  [[ "$sha" =~ $sha_pattern ]] || ot_fail "invalid zip sha256 '$sha' (expected 64 lowercase hex characters)" || return 1
  [ -f "$template" ] || ot_fail "no cask template at $template" || return 1
  command -v ruby > /dev/null 2>&1 || ot_fail "missing tool: ruby" || return 1
  rendered="$(sed -e "s/{{VERSION}}/$version/g" -e "s/{{ZIP_SHA256}}/$sha/g" "$template")" \
    || ot_fail "rendering the cask failed" || return 1
  case "$rendered" in
    *"{{"*) ot_fail "the rendered cask still has a {{ placeholder" || return 1 ;;
  esac
  syntax="$(printf '%s\n' "$rendered" | ruby -c 2>&1)" || true
  [ "$syntax" = "Syntax OK" ] || ot_fail "the rendered cask fails ruby -c: $syntax" || return 1
  mkdir -p "$(dirname "$outfile")"
  printf '%s\n' "$rendered" > "$outfile" || ot_fail "writing $outfile failed"
}
