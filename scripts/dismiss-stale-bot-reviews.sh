#!/usr/bin/env bash
# dismiss-stale-bot-reviews.sh — thin I/O glue for the dismiss-stale-bot-reviews
# workflow (#1115). Gathers a PR's effective reviews and review threads, asks the
# pure decision core which allow-listed bot CHANGES_REQUESTED reviews are stale
# (on a superseded commit, with no open current thread by that bot), and dismisses
# exactly those via the GraphQL dismissPullRequestReview mutation. All decision
# logic lives in the sourced pure core below; this file only performs I/O.
#
# Usage:
#   dismiss-stale-bot-reviews.sh --owner <owner> --name <repo> --pr <number> [--apply]
#   dismiss-stale-bot-reviews.sh --owner <owner> --name <repo> --sweep [--apply]
#
# A PR carrying a hold label (needs-human-review, dev-lead:needs-human,
# dev-lead:hands-off) is skipped on both paths: nothing is dismissed and the run
# is not failed. An unreadable label list dismisses nothing and fails the run.
#
# --sweep pages through ALL open PRs and runs the same decision on each PR whose
# reviewDecision is CHANGES_REQUESTED. One PR's failure never stops the others.
#
# Requirements:
#   GH_TOKEN with `pull-requests: write` on the target repo (GITHUB_TOKEN is
#   sufficient). `gh` and `jq` on PATH.
#
# Failure rule: a failed read, an unreadable head, a failed or unconfirmed
# dismissal is an error — nothing more is dismissed on that PR where the state is
# unknown, other candidates/PRs are still processed, and the run exits non-zero at
# the end. A head that really moved is only a warning (exit 0). Fail-closed on the
# decision: a review whose staleness cannot be proven (missing oid) is left alone.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dismiss-stale-bot-reviews.sh
source "${SCRIPT_DIR}/lib/dismiss-stale-bot-reviews.sh"

OWNER="" NAME="" PR="" APPLY=false SWEEP=false

# Retry helper: bounded retry with exponential backoff (1s, 2s; scaled by DSBR_RETRY_UNIT, default 1). Returns the exit
# code of the command's final attempt.
gh_api_retry() {
  local max_retries=3 attempt=1 exit_code
  while true; do
    exit_code=0
    "$@" && return 0 || exit_code=$?
    if [[ $attempt -ge $max_retries ]]; then
      return "$exit_code"
    fi
    local backoff=$(( (2 ** (attempt - 1)) * ${DSBR_RETRY_UNIT:-1} ))
    echo "::warning::gh api call failed (attempt $attempt/$max_retries); retrying in ${backoff}s…" >&2
    sleep "$backoff"
    attempt=$((attempt + 1))
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --name)  NAME="$2";  shift 2 ;;
    --pr)    PR="$2";    shift 2 ;;
    --sweep) SWEEP=true; shift ;;
    --apply) APPLY=true; shift ;;
    --dry-run) shift ;; # dry-run is the default; flag is a no-op for explicitness
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OWNER" ]] || [[ -z "$NAME" ]] || { [[ -z "$PR" ]] && [[ "$SWEEP" != "true" ]]; }; then
  echo "::error::--owner, --name and one of --pr or --sweep are required" >&2
  exit 1
fi
if [[ -n "$PR" ]] && [[ "$SWEEP" = "true" ]]; then
  echo "::error::--pr and --sweep are mutually exclusive" >&2
  exit 1
fi

# EFFECTIVE, OPINIONATED (latest-per-reviewer) reviews — the set GitHub uses to
# compute reviewDecision. latestOpinionatedReviews, NOT latestReviews: a trailing
# COMMENTED review would otherwise mask a still-blocking CHANGES_REQUESTED (#1116).
# Paginated (100 per page) so a stale bot review past the first page is not dropped.
read -r -d '' REVIEWS_QUERY <<'GRAPHQL' || true
query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      headRefOid
      labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
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

# Review threads: a bot's review is kept while that bot has a thread that is
# unresolved and not outdated. Paginated like the reviews.
read -r -d '' THREADS_QUERY <<'GRAPHQL' || true
query($owner:String!, $name:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          comments(first: 1) { nodes { author { login } } }
        }
      }
    }
  }
}
GRAPHQL

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
HEAD_QUERY='query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) { pullRequest(number:$number) {
    headRefOid
    labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
  } }
}'

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions
SWEEP_QUERY='query($owner:String!, $name:String!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequests(states: OPEN, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number reviewDecision }
    }
  }
}'

# gql_errors <response> — 0 when the response carries a GraphQL errors envelope
# (HTTP 200 can carry partial data plus errors).
gql_errors() {
  jq -e '(.errors // []) | length > 0' <<<"$1" >/dev/null 2>&1
}

# next_cursor <response> <jq-path-to-connection> <current_cursor> — advance a
# pagination loop. Prints the next cursor and returns 0 to continue; returns 1 when
# there is no further page; returns 2 on an invalid continuation (hasNextPage with
# an empty or non-advancing cursor), which would loop forever or truncate results.
next_cursor() {
  local response="$1" path="$2" current="$3" has_next end_cursor
  has_next="$(jq -r "${path}.pageInfo.hasNextPage // false" <<<"$response")"
  [[ "$has_next" = "true" ]] || return 1
  end_cursor="$(jq -r "${path}.pageInfo.endCursor // \"\"" <<<"$response")"
  if [[ -z "$end_cursor" ]] || [[ "$end_cursor" = "$current" ]]; then
    return 2
  fi
  printf '%s' "$end_cursor"
}

# gql_page <query> <cursor> [extra gh args…] — one paginated GraphQL call. owner and
# name are raw strings (-f); number must be -F so it resolves to Int!.
gql_page() {
  local query="$1" cursor="$2"; shift 2
  local -a cursor_arg
  if [[ -z "$cursor" ]]; then cursor_arg=(-F cursor=null); else cursor_arg=(-f "cursor=$cursor"); fi
  gh_api_retry gh api graphql -f query="$query" "${cursor_arg[@]}" -f owner="$OWNER" -f name="$NAME" "$@"
}

# Number of PRs skipped this run because they carry a hold label.
HELD_COUNT=0

# read_labels <response> — print the PR's label names, one per line, and return 0.
# Returns 1 when the list is unreadable: malformed JSON, labels null or missing,
# nodes not a list, a non-string name, or hasNextPage not exactly false. An empty
# nodes list is readable. (No `-e`: an empty list prints nothing, which is fine.)
read_labels() {
  jq -r '
    .data.repository.pullRequest.labels
    | if type == "object"
        and (.pageInfo | type == "object") and (.pageInfo.hasNextPage == false)
        and (.nodes | type == "array")
        and all(.nodes[]; type == "object" and (.name | type == "string"))
      then .nodes[].name
      else error("unreadable labels")
      end
  ' <<<"$1" 2>/dev/null
}

# process_pr <number> — returns 0 (handled, incl. nothing to do / head moved) or 1
# (an error occurred; the caller exits non-zero at the end).
process_pr() {
  local pr="$1" tag="${OWNER}/${NAME}#${1}"
  local labels="" hold=""
  local head_oid="" reviews="" threads="" cursor="" first=true response page next rc

  # ---- reviews (paged) ----
  while true; do
    response="$(gql_page "$REVIEWS_QUERY" "$cursor" -F number="$pr")" || {
      echo "::error::could not read reviews for ${tag}" >&2; return 1; }
    if gql_errors "$response"; then
      echo "::error::GraphQL error while fetching reviews for ${tag}: $(jq -r '.errors[0].message // "unknown error"' <<<"$response")" >&2
      return 1
    fi
    if [[ "$first" = "true" ]]; then
      head_oid="$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$response")" || {
        echo "::error::malformed reviews response for ${tag}" >&2; return 1; }
      if [[ -z "$head_oid" ]]; then
        echo "::warning::could not resolve head oid for ${tag} (PR not found or not accessible); nothing to do"
        return 0
      fi
      labels="$(read_labels "$response")" || {
        echo "::error::could not read the labels of ${tag}; dismissing nothing" >&2; return 1; }
      if hold="$(dsbr_hold_label "$labels")"; then
        echo "::notice::${tag} is held for a human by label '${hold}'; dismissing nothing"
        HELD_COUNT=$((HELD_COUNT + 1))
        return 0
      fi
      first=false
    fi
    page="$(jq -r '
      .data.repository.pullRequest.latestOpinionatedReviews.nodes[]
      | [ .id, .state, (.commit.oid // ""), (.author.login // ""), (.author.__typename // "") ]
      | @tsv
    ' <<<"$response")" || { echo "::error::malformed reviews response for ${tag}" >&2; return 1; }
    [[ -n "$page" ]] && reviews+="${page}"$'\n'
    rc=0
    next="$(next_cursor "$response" '.data.repository.pullRequest.latestOpinionatedReviews' "$cursor")" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "::error::invalid reviews pagination continuation for ${tag} (empty or non-advancing cursor)" >&2
      return 1
    fi
    [[ "$rc" -eq 0 ]] || break
    cursor="$next"
  done

  # ---- review threads (paged); unreadable => dismiss nothing on this PR ----
  cursor=""
  while true; do
    response="$(gql_page "$THREADS_QUERY" "$cursor" -F number="$pr")" || {
      echo "::error::could not read review threads for ${tag}; dismissing nothing" >&2; return 1; }
    if gql_errors "$response"; then
      echo "::error::GraphQL error while fetching review threads for ${tag}: $(jq -r '.errors[0].message // "unknown error"' <<<"$response"); dismissing nothing" >&2
      return 1
    fi
    page="$(jq -r '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | [ (.isResolved | tostring), (.isOutdated | tostring), (.comments.nodes[0].author.login // "") ]
      | @tsv
    ' <<<"$response")" || { echo "::error::malformed review-threads response for ${tag}; dismissing nothing" >&2; return 1; }
    [[ -n "$page" ]] && threads+="${page}"$'\n'
    rc=0
    next="$(next_cursor "$response" '.data.repository.pullRequest.reviewThreads' "$cursor")" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "::error::invalid review-threads pagination continuation for ${tag} (empty or non-advancing cursor); dismissing nothing" >&2
      return 1
    fi
    [[ "$rc" -eq 0 ]] || break
    cursor="$next"
  done

  # recheck_head <expected> — 0 same head, 1 head moved (warned), 2 unreadable
  # (head or labels), 3 a hold label appeared (noticed, counted).
  recheck_head() {
    local resp live live_labels live_hold
    resp="$(gh_api_retry gh api graphql -f query="$HEAD_QUERY" \
      -f owner="$OWNER" -f name="$NAME" -F number="$pr")" || {
      echo "::error::could not re-read the head for ${tag}" >&2; return 2; }
    if gql_errors "$resp"; then
      echo "::error::GraphQL error while rechecking head oid for ${tag}: $(jq -r '.errors[0].message // "unknown error"' <<<"$resp")" >&2
      return 2
    fi
    live="$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$resp")"
    [[ -n "$live" ]] || { echo "::error::head oid for ${tag} is unreadable on recheck" >&2; return 2; }
    live_labels="$(read_labels "$resp")" || {
      echo "::error::could not read the labels of ${tag} on recheck; dismissing nothing" >&2; return 2; }
    if live_hold="$(dsbr_hold_label "$live_labels")"; then
      echo "::notice::${tag} is held for a human by label '${live_hold}'; dismissing nothing more"
      HELD_COUNT=$((HELD_COUNT + 1))
      return 3
    fi
    if [[ "$live" != "$1" ]]; then
      echo "::warning::PR head moved from ${1} to ${live} for ${tag}; skipping remaining dismissals to avoid clearing a review on the new head"
      return 1
    fi
    return 0
  }

  # Revalidate the head before applying anything (it can move between the read and
  # the mutations, e.g. a force-push restoring a previously reviewed commit).
  rc=0; recheck_head "$head_oid" || rc=$?
  [[ "$rc" -eq 0 ]] || { [[ "$rc" -eq 1 || "$rc" -eq 3 ]] && return 0 || return 1; }

  local dismissed=0 would_dismiss=0 examined=0 failed=0
  local review_id state commit_oid login author_type msg mutation_resp new_state
  while IFS=$'\t' read -r review_id state commit_oid login author_type; do
    [[ -n "$review_id" ]] || continue
    examined=$((examined + 1))
    dsbr_should_dismiss "$state" "$commit_oid" "$head_oid" "$login" "$author_type" "" "$threads" "$labels" || continue

    # Revalidate before each mutation. An unreadable head is a FAILURE of this PR
    # (stop mutating, exit non-zero); a head that really moved is a warning.
    rc=0; recheck_head "$head_oid" || rc=$?
    if [[ "$rc" -eq 1 || "$rc" -eq 3 ]]; then return 0; fi
    if [[ "$rc" -ne 0 ]]; then return 1; fi

    msg="Superseded: dismissed by dismiss-stale-bot-reviews because ${login}'s CHANGES_REQUESTED review was on ${commit_oid} but the PR head is now ${head_oid}."
    msg+=" A still-valid finding returns as a fresh review on the new commit."
    if [[ "$APPLY" != "true" ]]; then
      echo "[dry-run] would dismiss review ${review_id} by ${login} (on ${commit_oid}, head ${head_oid})"
      would_dismiss=$((would_dismiss + 1))
      continue
    fi
    # Real `gh api graphql` exits non-zero on an errors envelope; tolerate that, log
    # an ::error:: naming the review, keep going, and fail the run at the end.
    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    if ! mutation_resp="$(gh_api_retry gh api graphql \
      -f query='mutation($id:ID!, $msg:String!) {
        dismissPullRequestReview(input:{pullRequestReviewId:$id, message:$msg}) {
          pullRequestReview { id state }
        }
      }' \
      -f id="$review_id" -f msg="$msg")"; then
      echo "::error::dismissal of review ${review_id} by ${login} on ${tag} failed; leaving it in place" >&2
      failed=$((failed + 1))
      continue
    fi
    if gql_errors "$mutation_resp"; then
      echo "::error::dismissal of review ${review_id} by ${login} on ${tag} returned a GraphQL errors envelope; leaving it in place" >&2
      failed=$((failed + 1))
      continue
    fi
    new_state="$(jq -r '.data.dismissPullRequestReview.pullRequestReview.state // ""' <<<"$mutation_resp")"
    if [[ "$new_state" != "DISMISSED" ]]; then
      echo "::error::dismissal of review ${review_id} by ${login} on ${tag} was not confirmed (state='${new_state:-<none>}'); leaving it in place" >&2
      failed=$((failed + 1))
      continue
    fi
    echo "Dismissed stale review ${review_id} by ${login} (was on ${commit_oid}, head ${head_oid})"
    dismissed=$((dismissed + 1))
  done <<<"$reviews"

  if [[ "$APPLY" != "true" ]]; then
    summary="dismiss-stale-bot-reviews [dry-run]: examined ${examined} effective review(s), would dismiss ${would_dismiss} stale bot review(s)"
    echo "${summary} on ${tag} (head ${head_oid}); no reviews were dismissed"
  else
    echo "dismiss-stale-bot-reviews: examined ${examined} effective review(s), dismissed ${dismissed} stale bot review(s) on ${tag} (head ${head_oid})"
  fi
  [[ "$failed" -eq 0 ]]
}

# sweep — page through every open PR and process those blocked by CHANGES_REQUESTED.
sweep() {
  local cursor="" response page next rc number checked=0 blocked=0 failed=0
  local -a numbers=()
  HELD_COUNT=0
  while true; do
    response="$(gql_page "$SWEEP_QUERY" "$cursor")" || {
      echo "::error::could not list open PRs for ${OWNER}/${NAME}" >&2; return 1; }
    if gql_errors "$response"; then
      echo "::error::GraphQL error while listing open PRs for ${OWNER}/${NAME}: $(jq -r '.errors[0].message // "unknown error"' <<<"$response")" >&2
      return 1
    fi
    page="$(jq -r '
      .data.repository.pullRequests.nodes[]
      | [ (.number | tostring), (.reviewDecision // "") ] | @tsv
    ' <<<"$response")" || { echo "::error::malformed PR list response" >&2; return 1; }
    while IFS=$'\t' read -r number state; do
      [[ -n "$number" ]] || continue
      checked=$((checked + 1))
      if [[ "$state" = "CHANGES_REQUESTED" ]]; then numbers+=("$number"); blocked=$((blocked + 1)); fi
    done <<<"$page"
    rc=0
    next="$(next_cursor "$response" '.data.repository.pullRequests' "$cursor")" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "::error::invalid PR-list pagination continuation (empty or non-advancing cursor)" >&2
      return 1
    fi
    [[ "$rc" -eq 0 ]] || break
    cursor="$next"
  done

  for number in "${numbers[@]+"${numbers[@]}"}"; do
    if ! process_pr "$number"; then
      echo "::error::sweep: ${OWNER}/${NAME}#${number} failed; continuing with the remaining PRs" >&2
      failed=$((failed + 1))
    fi
  done
  echo "dismiss-stale-bot-reviews sweep: checked ${checked} open PR(s), ${blocked} blocked by CHANGES_REQUESTED, ${failed} failed on ${OWNER}/${NAME}, ${HELD_COUNT} held by a label"
  [[ "$failed" -eq 0 ]]
}

if [[ "$SWEEP" = "true" ]]; then
  sweep
else
  process_pr "$PR"
fi
