#!/usr/bin/env bash
# scripts/lib/standards-staleness.sh — pure decision core for the standards
# channel staleness alarm (issue #1173).
#
# The moving channel standards/v<major>-stable is promoted by hand ("a human
# decides when", standards/standards-versioning.md). Nothing told that human
# WHEN: the channel once fell 14 commits and 8 standards/ files behind main
# unnoticed. This library decides, from facts the orchestrator
# scripts/standards-staleness.sh gathers with gh, whether the gap is worth an
# alarm, and renders the alarm issue.
#
# Side-effect-free and `source`-able: pure functions only, no gh/git/network
# (AGENTS.md → "Decision Logic Lives in a Pure, Tested Script").
#
# shellcheck shell=bash

if [ -n "${_STANDARDS_STALENESS_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_STANDARDS_STALENESS_SOURCED=1

# ss_standards_files — stdin: changed file paths, one per line. stdout: the ones
# under standards/. Everything else in the repo is not part of the artifact.
ss_standards_files() { grep -E '^standards/' || true; }

# ss_workflow_files — stdin: file paths. stdout: the ones under
# standards/workflows/. A changed template reaches every seeded repo, so one of
# these alarms at once, whatever its age.
ss_workflow_files() { grep -E '^standards/workflows/' || true; }

# ss_tree_diff <base_listing> <head_listing> — the files that differ between two
# listings of standards/. Each listing is a file of "<path>\t<blob sha>" lines.
# stdout: "<status>\t<path>" lines sorted by path, status ∈ added|modified|removed.
# Equal blob SHAs mean byte-identical files, so nothing is reported for them.
ss_tree_diff() {
  local base="${1:-}" head="${2:-}"
  [ -r "$base" ] && [ -r "$head" ] || return 1
  awk -F'\t' '
    FILENAME == ARGV[1] { if ($1 != "") b[$1] = $2; next }
    $1 != "" { h[$1] = $2 }
    END {
      for (p in h) { if (!(p in b)) print "added\t" p; else if (b[p] != h[p]) print "modified\t" p }
      for (p in b) if (!(p in h)) print "removed\t" p
    }
  ' "$base" "$head" | sort -t "$(printf '\t')" -k2
}

# ss_age_days <now_epoch> <then_epoch> — whole days from <then> to <now>, never
# negative. Empty (rc 1) when either is not a non-negative integer.
ss_age_days() {
  local now="${1:-}" then="${2:-}"
  [[ "$now" =~ ^[0-9]+$ && "$then" =~ ^[0-9]+$ ]] || return 1
  if [ "$then" -ge "$now" ]; then echo 0; return 0; fi
  echo $(( (now - then) / 86400 ))
}

# ss_decision <n_standards_files> <n_workflow_files> <age_days> <max_days>
# Echoes exactly one of:
#   FRESH            — standards/ is identical on the channel and the branch.
#   PENDING          — it differs, but no template changed and the oldest
#                      unpublished change is at most <max_days> old.
#   STALE workflows  — a file under standards/workflows/ differs.
#   STALE age        — the oldest unpublished change is more than <max_days> old.
#   UNKNOWN          — the inputs cannot be judged (a count or an age is not a
#                      number). The caller must fail, not treat it as fresh.
ss_decision() {
  local n="${1:-}" wf="${2:-}" age="${3:-}" max="${4:-}"
  [[ "$n" =~ ^[0-9]+$ && "$wf" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || { echo "UNKNOWN"; return 0; }
  if [ "$n" -eq 0 ]; then echo "FRESH"; return 0; fi
  if [ "$wf" -gt 0 ]; then echo "STALE workflows"; return 0; fi
  [[ "$age" =~ ^[0-9]+$ ]] || { echo "UNKNOWN"; return 0; }
  if [ "$age" -gt "$max" ]; then echo "STALE age"; return 0; fi
  echo "PENDING"
}

# ss_issue_marker <channel> — the hidden body marker that identifies the one
# standing alarm issue for <channel>, so a run updates it instead of opening a
# second one.
ss_issue_marker() { printf '<!-- standards-channel-staleness channel=%s -->' "${1:-}"; }

# ss_issue_title <channel> <branch>
ss_issue_title() { printf 'Standards channel %s is behind %s — promote it' "${1:-}" "${2:-}"; }

# ss_reason_text <decision> <age_days> <max_days> <age_is_upper_bound(0|1)>
# One sentence saying why the alarm fired.
ss_reason_text() {
  local decision="${1:-}" age="${2:-}" max="${3:-}" bound="${4:-0}" at=""
  [ "$bound" = "1" ] && at="at most "
  case "$decision" in
    "STALE workflows")
      printf 'A workflow template under `standards/workflows/` differs. Templates reach every seeded repo, so this alarms at once.' ;;
    "STALE age")
      printf 'The oldest unpublished change to `standards/` is %s%s days old. The limit is %s days.' "$at" "$age" "$max" ;;
    *) printf 'Decision: %s.' "$decision" ;;
  esac
}

# ss_issue_body <channel> <channel_sha> <branch> <branch_sha> <ahead_by>
#               <decision> <age_days> <max_days> <age_is_upper_bound>
# stdin: the differing standards/ files as "<status>\t<path>" lines.
# stdout: the Markdown body of the alarm issue.
ss_issue_body() {
  local channel="${1:-}" channel_sha="${2:-}" branch="${3:-}" branch_sha="${4:-}" ahead="${5:-}"
  local decision="${6:-}" age="${7:-}" max="${8:-}" bound="${9:-0}"
  local status path n=0 rows=""
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    rows="${rows}| \`${path}\` | ${status} |"$'\n'
    n=$((n + 1))
  done
  ss_issue_marker "$channel"
  printf '\n\n'
  printf '`%s` (commit `%s`) is behind `%s` (commit `%s`) by %s commit(s). %s file(s) under `standards/` differ.\n\n' \
    "$channel" "${channel_sha:0:12}" "$branch" "${branch_sha:0:12}" "$ahead" "$n"
  ss_reason_text "$decision" "$age" "$max" "$bound"
  printf '\n\n## Files that differ\n\n| File | Change |\n|---|---|\n%s' "$rows"
  cat <<'MD'

## What to do

A promotion is fleet-wide. The channel has no rings and no canary stage, so every consumer sees the new content at once. Verify first, then cut:

```bash
# 1. Every known channel consumer must pass against the candidate commit.
bash scripts/cut-standards-release.sh verify <green-main-sha>

# 2. Preview, then cut. --verify re-runs step 1 and refuses to cut on a failure.
bash scripts/cut-standards-release.sh cut vX.Y.Z --commit <green-main-sha> --verify --dry-run
bash scripts/cut-standards-release.sh cut vX.Y.Z --commit <green-main-sha> --verify
```

See `standards/standards-versioning.md`. This issue is updated on each run and closed automatically once the channel catches up.
MD
}
