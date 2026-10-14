#!/usr/bin/env bash
# reconcile-backlog.sh — periodic/manual backlog reconcile for add-to-project.
#
# Why this exists (combsmith/.github#518): the event-driven add-to-project
# path misses qualifying items in two structural cases —
#   1. issues/PRs created by the default GITHUB_TOKEN (app/github-actions):
#      GitHub does not fire workflows from default-token events, so
#      `issues: opened` never triggers the add; and
#   2. runs dropped under runner congestion (no retry).
# This scans each repo's OPEN issues/PRs + Ideas discussions and reconciles each
# with the board using the SAME gate + helpers as the event path
# (evaluate_noise_gate / reconcile_content_with_project / reconcile_discussion),
# so a missed item lands within one reconcile cycle regardless of author/token.
# Idempotent; honours DRY_RUN=1 (logs intended actions, mutates nothing).
#
# Env:
#   PROJECT_ID       ProjectV2 node ID of the Initiatives project   (required)
#   PROJECT_URL      human-readable URL (logging only)
#   REQUIRED_LABEL   gate's required label   (default: dev-lead)
#   EXCLUDED_LABELS  gate's excluded labels  (default in add-issue-or-pr.sh)
#   IDEAS_CATEGORY   discussion category tracked as drafts (default: Ideas)
#   RECON_REPOS      space-separated owner/repo list to scan
#                    (default: the planner App installation's repositories)
#   DRY_RUN          "1" → log only
#   GH_TOKEN         planner App installation token (issues/PRs read + project write)
set -euo pipefail

_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/add-to-project/add-issue-or-pr.sh
source "${_dir}/add-issue-or-pr.sh"       # reconcile_content_with_project (+ lib.sh)
# shellcheck source=.github/scripts/add-to-project/reconcile-discussion.sh
source "${_dir}/reconcile-discussion.sh"  # reconcile_discussion

: "${PROJECT_ID:?PROJECT_ID is required}"
ideas_category="${IDEAS_CATEGORY:-Ideas}"
# Exported (with default applied) so the discussions --jq filter can read it via
# `env.RECON_IDEAS_CATEGORY` instead of shell-interpolating it — avoids jq syntax
# breakage / injection if the category name contains quotes or backslashes.
export RECON_IDEAS_CATEGORY="${ideas_category}"

# Resolve target repos: explicit RECON_REPOS, else the App installation's repos.
declare -a repos
if [ -n "${RECON_REPOS:-}" ]; then
  read -r -a repos <<< "${RECON_REPOS}"
else
  mapfile -t repos < <(gh api --paginate /installation/repositories --jq '.repositories[].full_name')
fi
if [ "${#repos[@]}" -eq 0 ]; then
  echo "::error::no repos to reconcile (set RECON_REPOS or check the App installation)" >&2
  exit 64
fi

scanned=0
echo "Reconciling ${#repos[@]} repo(s) into ${PROJECT_URL:-the project}${DRY_RUN:+ (DRY RUN)}"
for repo in "${repos[@]}"; do
  [ -z "$repo" ] && continue
  echo "::group::${repo}"

  # Open issues AND PRs (the issues endpoint returns both; the gate applies to
  # both identically). Pass labels as the objects array the gate expects.
  # Fetch into a variable so an API failure is surfaced (not silenced) and
  # `set -e`'s check isn't bypassed by a subshell; feed the loop via here-string
  # so it stays in the parent shell and `scanned` is updated correctly.
  issues_tsv=$(gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
            --jq '.[] | [.node_id, .html_url, ([.labels[] | {name}] | @json)] | @tsv') || {
    echo "::error::failed to fetch issues for ${repo}" >&2
    echo "::endgroup::"
    continue
  }
  while IFS=$'\t' read -r nid url labels; do
    [ -z "$nid" ] && continue
    scanned=$((scanned + 1))
    reconcile_content_with_project "$nid" "$url" "$labels" || true
  done <<< "$issues_tsv"

  # Open Ideas-category discussions → draft items. Same robustness as above; the
  # category is read inside jq via `env.RECON_IDEAS_CATEGORY` (set earlier) rather
  # than shell-interpolated, so special characters can't break or inject into it.
  discussions_tsv=$(gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo##*/}" -f query='
    query($owner:String!,$name:String!,$endCursor:String){
      repository(owner:$owner,name:$name){
        discussions(first:100,after:$endCursor,states:OPEN){
          pageInfo{hasNextPage endCursor}
          nodes{number title url category{name}}
        }
      }
    }' --jq '.data.repository.discussions.nodes[] | select(.category.name==env.RECON_IDEAS_CATEGORY) | [(.number|tostring), .title, .url] | @tsv') || {
    echo "::error::failed to fetch discussions for ${repo}" >&2
    echo "::endgroup::"
    continue
  }
  while IFS=$'\t' read -r number title url; do
    [ -z "$number" ] && continue
    scanned=$((scanned + 1))
    reconcile_discussion "$number" "$title" "$url" "$ideas_category" || true
  done <<< "$discussions_tsv"

  echo "::endgroup::"
done

echo "Reconcile complete — scanned ${scanned} item(s) across ${#repos[@]} repo(s)."
