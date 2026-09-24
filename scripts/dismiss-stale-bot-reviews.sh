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

# Fetch the PR head oid plus the EFFECTIVE, OPINIONATED (latest-per-reviewer)
# reviews — the exact set GitHub uses to compute reviewDecision — so we never
# dismiss an older review that a newer APPROVE already superseded. We query
# latestOpinionatedReviews, NOT latestReviews: latestReviews returns each
# reviewer's single most-recent review of ANY kind, so when an allow-listed bot
# posts a COMMENTED review after its earlier CHANGES_REQUESTED, latestReviews
# surfaces only the COMMENTED one — even though a comment does not clear the
# change request and reviewDecision stays blocked. The loop would then see
# COMMENTED, never dismiss the still-blocking CHANGES_REQUESTED, and the PR would
# remain blocked forever (#1116). latestOpinionatedReviews returns each
# reviewer's latest APPROVED/CHANGES_REQUESTED review — the review that actually
# drives reviewDecision — so a trailing COMMENTED can no longer mask a stale
# change request. It is a paginated connection capped at 100 nodes per page: a
# single unpaginated page would silently drop every effective review past the
# first 100 distinct reviewers, so a stale bot CHANGES_REQUESTED beyond that
# cut-off would survive while the script reported success (fail-open, #1116).
# Page through the whole connection so the decision core sees the complete set.
read -r -d '' QUERY <<'GRAPHQL' || true
query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      headRefOid
      latestOpinionatedReviews(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
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
head_oid="" reviews="" cursor="" first=true
while true; do
  # cursor="" => first page (pass JSON null, -F); otherwise pass the string (-f).
  if [ -z "$cursor" ]; then
    cursor_arg=(-F cursor=null)
  else
    cursor_arg=(-f "cursor=$cursor")
  fi
  response="$(gh api graphql \
    -f query="$QUERY" \
    "${cursor_arg[@]}" \
    -f owner="$OWNER" -f name="$NAME" -F number="$PR")"

  # Resolve the head oid once, from the first page, and fail-loud-then-noop if the
  # PR cannot be resolved — before examining any reviews.
  if [ "$first" = "true" ]; then
    head_oid="$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$response")"
    if [ -z "$head_oid" ]; then
      echo "::warning::could not resolve head oid for ${OWNER}/${NAME}#${PR}; nothing to do"
      exit 0
    fi
    first=false
  fi

  # Emit one TAB-separated record per review: id, state, commit_oid, login, type.
  page_reviews="$(jq -r '
    .data.repository.pullRequest.latestOpinionatedReviews.nodes[]
    | [ .id, .state, (.commit.oid // ""), (.author.login // ""), (.author.__typename // "") ]
    | @tsv
  ' <<<"$response")"
  [ -n "$page_reviews" ] && reviews+="${page_reviews}"$'\n'

  has_next="$(jq -r '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.hasNextPage // false' <<<"$response")"
  end_cursor="$(jq -r '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo.endCursor // ""' <<<"$response")"
  [ "$has_next" = "true" ] && [ -n "$end_cursor" ] || break
  cursor="$end_cursor"
done

# Revalidate the PR head immediately before applying any dismissal. The head can
# move between the paginated read above and the mutation loop below — e.g. a
# force-push that restores a previously reviewed commit. Our supersede decisions
# were computed against the cached head_oid, so a bot review that now sits on the
# *current* head could satisfy review_oid != head_oid and be wrongly dismissed
# even though it is no longer stale. Re-read the head and no-op the whole run if
# it changed; the synchronize/submitted event for the new head re-runs us against
# the settled state (#1116).
recheck="$(gh api graphql \
  -f query='query($owner:String!, $name:String!, $number:Int!) {
    repository(owner:$owner, name:$name) { pullRequest(number:$number) { headRefOid } }
  }' \
  -f owner="$OWNER" -f name="$NAME" -F number="$PR")"
current_head="$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$recheck")"
if [ "$current_head" != "$head_oid" ]; then
  echo "::warning::PR head moved from ${head_oid} to ${current_head:-<unresolved>} during the review read for ${OWNER}/${NAME}#${PR}; skipping dismissals this run to avoid clearing a review on the new head"
  exit 0
fi

dismissed=0 would_dismiss=0 examined=0
while IFS=$'\t' read -r review_id state commit_oid login author_type; do
  [ -n "$review_id" ] || continue
  examined=$((examined + 1))
  if ! dsbr_should_dismiss "$state" "$commit_oid" "$head_oid" "$login" "$author_type"; then
    continue
  fi
  msg="Superseded: dismissed by dismiss-stale-bot-reviews because ${login}'s CHANGES_REQUESTED review was on ${commit_oid} but the PR head is now ${head_oid}. A still-valid finding returns as a fresh review on the new commit."
  if [ "$DRY_RUN" = "true" ]; then
    # Dry-run performs NO mutation, so a candidate must NOT be counted as
    # dismissed — track it in a separate would-dismiss tally instead, or the
    # summary would report reviews as dismissed that are still in place,
    # misleading any operator/automation consuming the output (#1116).
    echo "[dry-run] would dismiss review ${review_id} by ${login} (on ${commit_oid}, head ${head_oid})"
    would_dismiss=$((would_dismiss + 1))
    continue
  fi
  mutation_resp="$(gh api graphql \
    -f query='mutation($id:ID!, $msg:String!) {
      dismissPullRequestReview(input:{pullRequestReviewId:$id, message:$msg}) {
        pullRequestReview { id state }
      }
    }' \
    -f id="$review_id" -f msg="$msg")"
  # GitHub GraphQL can return HTTP 200 with an `errors` envelope (e.g. the review
  # was already dismissed by another actor), and `gh` exits 0 in that case. Count
  # a dismissal as successful ONLY when there is no errors envelope AND the review
  # comes back in the DISMISSED state; otherwise it may still block the PR, so warn
  # and leave the count untouched rather than reporting a phantom dismissal (#1116).
  if jq -e '(.errors // []) | length > 0' <<<"$mutation_resp" >/dev/null 2>&1; then
    echo "::warning::dismissal of review ${review_id} by ${login} returned a GraphQL errors envelope; leaving it in place"
    continue
  fi
  new_state="$(jq -r '.data.dismissPullRequestReview.pullRequestReview.state // ""' <<<"$mutation_resp")"
  if [ "$new_state" != "DISMISSED" ]; then
    echo "::warning::dismissal of review ${review_id} by ${login} was not confirmed (state='${new_state:-<none>}'); leaving it in place"
    continue
  fi
  echo "Dismissed stale review ${review_id} by ${login} (was on ${commit_oid}, head ${head_oid})"
  dismissed=$((dismissed + 1))
done <<<"$reviews"

if [ "$DRY_RUN" = "true" ]; then
  echo "dismiss-stale-bot-reviews [dry-run]: examined ${examined} effective review(s), would dismiss ${would_dismiss} stale bot review(s) on ${OWNER}/${NAME}#${PR} (head ${head_oid}); no reviews were dismissed"
else
  echo "dismiss-stale-bot-reviews: examined ${examined} effective review(s), dismissed ${dismissed} stale bot review(s) on ${OWNER}/${NAME}#${PR} (head ${head_oid})"
fi
