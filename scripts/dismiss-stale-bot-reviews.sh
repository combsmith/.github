#!/usr/bin/env bash
# dismiss-stale-bot-reviews.sh — thin I/O glue for the dismiss-stale-bot-reviews
# workflow (#1115). Gathers a PR's effective reviews, asks the pure decision core
# which allow-listed bot CHANGES_REQUESTED reviews are stale (on a superseded
# commit), and dismisses exactly those via the GraphQL dismissPullRequestReview
# mutation. All of the decision logic lives in the sourced pure core below; this
# file only performs I/O (gh GraphQL reads + the dismissal mutation).
#
# Usage:
#   dismiss-stale-bot-reviews.sh --owner <owner> --name <repo> --pr <number> [--dry-run]
#
# Requirements:
#   GH_TOKEN with `pull-requests: write` on the target repo (GITHUB_TOKEN is
#   sufficient — the mutation acts within the same repo). `gh` and `jq` on PATH.
#
# Fail-loud: a failed GraphQL read aborts (set -euo pipefail). Fail-closed on the
# decision: a review whose staleness cannot be proven (missing oid) is left alone.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dismiss-stale-bot-reviews.sh
source "${SCRIPT_DIR}/lib/dismiss-stale-bot-reviews.sh"

OWNER="" NAME="" PR="" DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)   OWNER="$2"; shift 2 ;;
    --name)    NAME="$2";  shift 2 ;;
    --pr)      PR="$2";    shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$OWNER" ] || [ -z "$NAME" ] || [ -z "$PR" ]; then
  echo "::error::--owner, --name and --pr are required" >&2
  exit 1
fi

# Fetch the PR head oid plus the EFFECTIVE (latest-per-reviewer) reviews — the
# exact set GitHub uses to compute reviewDecision — so we never dismiss an older
# review that a newer APPROVE already superseded.
read -r -d '' QUERY <<'GRAPHQL' || true
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      headRefOid
      latestReviews(first: 100) {
        nodes {
          id
          state
          commit { oid }
          author { login __typename }
        }
      }
    }
  }
}
GRAPHQL

# owner/name are passed as raw strings (-f) so a repo named like a number/bool is
# never type-coerced; number must be -F so it resolves to the GraphQL Int!.
response="$(gh api graphql \
  -f query="$QUERY" \
  -f owner="$OWNER" -f name="$NAME" -F number="$PR")"

head_oid="$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$response")"
if [ -z "$head_oid" ]; then
  echo "::warning::could not resolve head oid for ${OWNER}/${NAME}#${PR}; nothing to do"
  exit 0
fi

# Emit one TAB-separated record per review: id, state, commit_oid, login, type.
reviews="$(jq -r '
  .data.repository.pullRequest.latestReviews.nodes[]
  | [ .id, .state, (.commit.oid // ""), (.author.login // ""), (.author.__typename // "") ]
  | @tsv
' <<<"$response")"

dismissed=0 examined=0
while IFS=$'\t' read -r review_id state commit_oid login author_type; do
  [ -n "$review_id" ] || continue
  examined=$((examined + 1))
  if ! dsbr_should_dismiss "$state" "$commit_oid" "$head_oid" "$login" "$author_type"; then
    continue
  fi
  msg="Superseded: dismissed by dismiss-stale-bot-reviews because ${login}'s CHANGES_REQUESTED review was on ${commit_oid} but the PR head is now ${head_oid}. A still-valid finding returns as a fresh review on the new commit."
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] would dismiss review ${review_id} by ${login} (on ${commit_oid}, head ${head_oid})"
    dismissed=$((dismissed + 1))
    continue
  fi
  gh api graphql \
    -f query='mutation($id:ID!, $msg:String!) {
      dismissPullRequestReview(input:{pullRequestReviewId:$id, message:$msg}) {
        pullRequestReview { id state }
      }
    }' \
    -f id="$review_id" -f msg="$msg" >/dev/null
  echo "Dismissed stale review ${review_id} by ${login} (was on ${commit_oid}, head ${head_oid})"
  dismissed=$((dismissed + 1))
done <<<"$reviews"

echo "dismiss-stale-bot-reviews: examined ${examined} effective review(s), dismissed ${dismissed} stale bot review(s) on ${OWNER}/${NAME}#${PR} (head ${head_oid})"
