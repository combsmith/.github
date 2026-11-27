#!/usr/bin/env bash
# check-nosonar-markers.sh — PR-time gate for inline SonarCloud suppression
# markers (#1613). The rule lives in scripts/lib/nosonar-markers.sh; see
# docs/initiatives/sonarcloud-suppression-adr.md for the decision.
#
# Usage:
#   check-nosonar-markers.sh --base <ref>   diff mode (CI): fail only on invalid
#                                           markers on lines added since <ref>,
#                                           and on added sonar.issue.ignore.* keys
#   check-nosonar-markers.sh [path...]      tree mode: check every tracked file
#                                           (or just the given paths); fails on
#                                           any invalid marker. sonar.issue.ignore
#                                           keys are printed as warnings only,
#                                           since legacy entries are still being
#                                           migrated.
#
# Diff mode only gates what a change adds, so existing markers never block an
# unrelated PR. The org-wide sweep of existing markers is the compliance audit's
# check_nosonar_markers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nosonar-markers.sh
. "$SCRIPT_DIR/lib/nosonar-markers.sh"

base=""
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) paths+=("$1"); shift ;;
  esac
done

# Escape text for a GitHub Actions workflow command so PR-controlled paths and
# messages cannot inject a second command. $2 = 1 also escapes property delimiters.
gha_escape() {
  local s="$1"
  s="${s//'%'/'%25'}"; s="${s//$'\r'/'%0D'}"; s="${s//$'\n'/'%0A'}"
  if [[ "${2:-0}" == 1 ]]; then s="${s//':'/'%3A'}"; s="${s//','/'%2C'}"; fi
  printf '%s' "$s"
}

annotate() { # <level> <path> <line> <message>
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::$1 file=$(gha_escape "$2" 1),line=$(gha_escape "$3" 1)::$(gha_escape "$4")"
  else
    echo "$2:$3: $1: $4"
  fi
}

is_excluded() {
  case "$1" in
    node_modules/* | */node_modules/* | vendor/* | */vendor/*) return 0 ;;
  esac
  return 1
}

# added_lines <ref> <path>: the new-side line numbers a diff adds to <path>.
added_lines() {
  # Diff the whole change with rename detection (-M), then filter by the new path,
  # so a pure rename pairs old/new and adds no lines.
  git -c core.quotePath=false diff -U0 --no-color --no-ext-diff -M --src-prefix=a/ --dst-prefix=b/ "$1" HEAD | awk -v target="$2" '
    /^diff --git / { hdr = 1; next }
    hdr && /^\+\+\+ / {
      hdr = 0
      file = substr($0, 5); sub(/\t.*$/, "", file); sub(/^b\//, "", file)
      next
    }
    /^@@/ && file == target {
      split($3, a, ","); start = substr(a[1], 2); n = (a[2] == "") ? 1 : a[2]
      for (i = 0; i < n; i++) print start + i
    }'
}

fail=0

if [[ -n "$base" ]]; then
  git rev-parse --verify --quiet "$base^{commit}" > /dev/null \
    || { echo "::error::check-nosonar-markers: base ref '$base' not found (fetch more history)"; exit 2; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    is_excluded "$f" && continue
    [[ -f "$f" ]] || continue
    added=$(added_lines "$base" "$f")
    [[ -n "$added" ]] || continue
    if [[ "${f##*/}" == "sonar-project.properties" ]]; then
      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        ln="${hit%%:*}"
        if grep -qxF "$ln" <<< "$added"; then
          annotate error "$f" "$ln" "${hit#*: } — sonar.issue.ignore.* is deprecated; suppress with an inline NOSONAR(<rule>) <reason> marker instead (docs/initiatives/sonarcloud-suppression-adr.md)"
          fail=1
        fi
      done < <(nosonar_issue_ignore_lines "$(cat "$f")")
      continue
    fi
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      rest="${v#"$f":}"; ln="${rest%%:*}"; msg="${rest#*: }"
      if grep -qxF "$ln" <<< "$added"; then
        annotate error "$f" "$ln" "$msg"
        fail=1
      fi
    done < <(nosonar_scan_file "$f")
  done < <(git -c core.quotePath=false diff --name-only --diff-filter=AMR "$base" HEAD)
else
  if [[ ${#paths[@]} -eq 0 ]]; then
    mapfile -t paths < <(git -c core.quotePath=false ls-files)
  fi
  for f in "${paths[@]}"; do
    is_excluded "$f" && continue
    [[ -f "$f" ]] || continue
    if [[ "${f##*/}" == "sonar-project.properties" ]]; then
      while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        annotate warning "$f" "${hit%%:*}" "${hit#*: } — sonar.issue.ignore.* is deprecated; migrate it to an inline marker"
      done < <(nosonar_issue_ignore_lines "$(cat "$f")")
      continue
    fi
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      rest="${v#"$f":}"
      annotate error "$f" "${rest%%:*}" "${rest#*: }"
      fail=1
    done < <(nosonar_scan_file "$f")
  done
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Invalid NOSONAR marker(s). Each marker must name the rule in the analyzer's syntax and give a reason." >&2
  echo "Standard: standards/ci-standards.md#sonarcloud-suppression-policy" >&2
  exit 1
fi
echo "NOSONAR markers OK"
