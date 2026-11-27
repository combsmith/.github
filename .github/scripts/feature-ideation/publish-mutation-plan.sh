#!/usr/bin/env bash
# publish-mutation-plan.sh — validate the analyst's Discussion mutation plan
# and, unless the caller asked for a dry run, execute it (#1389).
#
# Runs in the reusable workflow's `publish` job, which has NO model. The
# analyst job holds only a read-only token and records its mutations to a
# JSONL plan (discussion-mutations.sh with DRY_RUN=1). Everything that decides
# whether and where to write comes from the caller's inputs, passed in by the
# workflow — never from the plan or the model job:
#   - CALLER_DRY_RUN=1 → validate and report, write nothing
#   - TARGET_DISCUSSION set → the one allowed comment target is resolved here
#     from the caller's number; the plan's ids are only compared against it
#
# Env:
#   PLAN_PATH          the plan (JSONL); missing or empty = nothing to publish
#   CALLER_DRY_RUN     "1"/"true" = dry run
#   TARGET_DISCUSSION  caller's target_discussion (single-idea mode when set)
#   ENHANCE_BACKLOG    "1"/"true" = backlog mode (ignored when a target is set)
#   REPO               owner/name of the calling repository
#   GH_TOKEN           token with discussions: write (read is enough on dry run)
#   PUBLISH_WRITE_DELAY_SECONDS  pause after each write (default 1), to stay
#                      under GitHub's secondary rate limit for mutations
#   PUBLISH_LEDGER_IN  directory of the ledgers earlier attempts of this
#                      workflow run uploaded (any *.jsonl below it); missing =
#                      no earlier attempt
#   PUBLISH_LEDGER_OUT this attempt's ledger, appended to after each write;
#                      required unless dry run. The workflow uploads it as an
#                      artifact of the run with if: always().
#
# Exit: 0 published (or dry run / nothing to do); 1 plan rejected; other
# non-zero = a GitHub call failed. Publishing is not atomic, so mutations before
# the failure stay applied, but a re-run of the job is safe (#1456): every
# Discussion created and comment posted is recorded in the ledger as soon as it
# succeeds, and a re-run attempt skips the entries the earlier attempts'
# ledgers record — state only this workflow run holds, not markers in comments,
# which anyone posting as github-actions[bot] could plant. Labels are not
# recorded; they are re-applied, which GitHub treats as a no-op. A write whose
# response was lost (GitHub applied it, the call still failed) is not recorded
# and would be repeated by a re-run.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-safe.sh
. "${SCRIPT_DIR}/lib/gh-safe.sh"
# shellcheck source=lib/mutation-plan.sh
. "${SCRIPT_DIR}/lib/mutation-plan.sh"
# shellcheck source=discussion-mutations.sh
. "${SCRIPT_DIR}/discussion-mutations.sh"

_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Make text that may carry model- or caller-supplied values safe to log (the
# text being published is handled by mp_sanitise_plan, which has another job):
# no carriage returns, no `::` (a log line starting with it is a workflow
# command), no backticks (they could close the summary's code fence).
_neutralise() {
  tr -d '\r' | sed -e ':a' -e 's/::/: :/' -e 'ta' -e "s/\`/'/g"
}

# Run a lookup with its stderr neutralised: GitHub's error text can echo ids
# and other values that came from the plan.
_quiet_stderr() {
  local err rc=0
  err=$(mktemp)
  "$@" 2>"$err" || rc=$?
  _neutralise <"$err" >&2
  rm -f "$err"
  return "$rc"
}

# nodes(ids:) lookup. An id GitHub cannot resolve (deleted, private, never
# existed) comes back as a NOT_FOUND error with a null node, and gh exits
# non-zero; that is an answer, not a failure: the node stays unresolved and the
# validator rejects the entry with a reason. Any other error fails.
_lookup_nodes() {
  local body="$1" raw rc=0
  raw=$(printf '%s' "$body" | gh api graphql --input - 2>/dev/null) || rc=$?
  if ! printf '%s' "$raw" | jq -e '.data.nodes | arrays' >/dev/null 2>&1; then
    echo "node lookup failed (exit ${rc})" >&2
    return 1
  fi
  if [[ "$rc" -ne 0 ]] && ! printf '%s' "$raw" | jq -e \
      '(.errors | arrays | length > 0) and all(.errors[]; .type == "NOT_FOUND")' >/dev/null 2>&1; then
    echo "node lookup returned errors (exit ${rc})" >&2
    return 1
  fi
  printf '%s' "$raw"
}

# Resolve what backlog and scheduled plans are checked against (#1389
# review): this repository's node id, the ideation category (Ideas, else
# General — the prompt's own fallback) and, for every existing Discussion the
# plan names, its category — only for Discussions of this repository. All
# from the workflow token; nothing here is read from the plan except the ids
# to look up. Prints the context JSON for mp_validate_plan.
_resolve_context() {
  local plan="$1" query repo_json repo_id cat_id ids body nodes targets='{}'
  read -r -d '' query <<'GRAPHQL' || true
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 25) { nodes { id slug name } }
    label(name: "enhancement") { id }
  }
}
GRAPHQL
  repo_json=$(gh_safe_graphql -f query="$query" \
    -f owner="${REPO%%/*}" -f name="${REPO##*/}" --jq '.data.repository') || return 1
  repo_id=$(printf '%s' "$repo_json" | jq -r '.id // ""')
  cat_id=$(mp_ideation_category "$(printf '%s' "$repo_json" | jq -c '.discussionCategories.nodes // []')")

  # nodes(ids:) takes at most 100 ids; any id beyond that stays unresolved
  # and is rejected (the comment cap rejects such a plan anyway).
  ids=$(mp_existing_targets "$plan" | jq -c '.[0:100]')
  if [[ "$(printf '%s' "$ids" | jq 'length')" -gt 0 ]]; then
    read -r -d '' query <<'GRAPHQL' || true
query($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on Discussion { id category { id } repository { id } }
  }
}
GRAPHQL
    body=$(jq -nc --arg q "$query" --argjson ids "$ids" '{query: $q, variables: {ids: $ids}}')
    nodes=$(_lookup_nodes "$body") || return 1
    targets=$(printf '%s' "$nodes" | jq -c --arg repo "$repo_id" '
      [.data.nodes[]? | objects
       | select((.id | type) == "string" and .repository.id == $repo)
       | {(.id): (.category.id // "")}] | add // {}')
  fi
  jq -nc --arg r "$repo_id" --arg c "$cat_id" --argjson t "$targets" \
    --arg l "$(printf '%s' "$repo_json" | jq -r '.label.id // ""')" \
    '{repo_id: $r, category_id: $c, label_id: $l, target_categories: $t}'
}

# GitHub asks for at least a second between mutating requests; without it a
# backlog run's 50 comments can hit the secondary rate limit part-way.
_pace() {
  sleep "${PUBLISH_WRITE_DELAY_SECONDS:-1}"
}

# A stable id for this plan: ledger entries count only for the plan they were
# recorded for, so a re-run attempt with a new plan starts afresh.
_plan_id() {
  local hash
  hash=$({ sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-16)
  [[ "$hash" =~ ^[0-9a-f]{16}$ ]] || return 1
  printf '%s' "$hash"
}

# What earlier attempts of this workflow run already published: mp_ledger_done
# JSON, from the ledgers in PUBLISH_LEDGER_IN. No comment or Discussion body is
# read. A ledger is an artifact of this run, so only a job of this run could
# have written one; still, every Discussion it says was created is checked to be
# an Ideas Discussion of this repository (metadata only), so a ledger cannot send
# a follow-up comment or label anywhere the plan rules would not allow.
# Returns non-zero when that cannot be established, so nothing is repeated or
# misdirected blindly.
_resolve_done() {
  local plan="$1" plan_id="$2" context="$3" files=() f recorded ids query body nodes bad
  if [[ -n "${PUBLISH_LEDGER_IN:-}" ]] && [[ -d "$PUBLISH_LEDGER_IN" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$PUBLISH_LEDGER_IN" -type f -name '*.jsonl' -print0 | sort -z)
  fi
  recorded=$(mp_ledger_done "$plan_id" "${files[@]+"${files[@]}"}") || return 1

  # Only the ids of entries that are creates in this plan matter.
  ids=$(printf '%s' "$plan" | jq -c --argjson recorded "$recorded" '
    [to_entries[] | select(.value.op == "create_discussion")
     | $recorded.created[.key | tostring] | strings] | unique')
  if [[ "$(printf '%s' "$ids" | jq 'length')" -gt 0 ]]; then
    read -r -d '' query <<'GRAPHQL' || true
query LedgerCreated($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on Discussion { id category { id } repository { id } }
  }
}
GRAPHQL
    body=$(jq -nc --arg q "$query" --argjson ids "$ids" '{query: $q, variables: {ids: $ids}}')
    nodes=$(_lookup_nodes "$body") || return 1
    bad=$(printf '%s' "$nodes" | jq -r --argjson ids "$ids" --argjson ctx "$context" '
      ([.data.nodes[]? | objects
        | select((.id | type) == "string"
                 and (($ctx.repo_id // "") | test("\\S")) and .repository.id == $ctx.repo_id
                 and (($ctx.category_id // "") | test("\\S")) and .category.id == $ctx.category_id)
        | .id]) as $ok
      | [$ids[] | select(. as $i | $ok | index($i) | not)] | length')
    if [[ "$bad" -ne 0 ]]; then
      echo "a ledger records ${bad} created Discussion(s) that are not Ideas Discussions of this repository" >&2
      return 1
    fi
  fi
  printf '%s' "$recorded"
}

# Record a published entry in this attempt's ledger, before the next write.
_record() {
  if ! mp_ledger_entry "$@" >>"$PUBLISH_LEDGER_OUT"; then
    echo "::error::Could not record a published entry in the re-run ledger; stopping so a re-run cannot repeat more than this one entry."
    return 1
  fi
}

# Resolve the caller's target number to its node id (empty unless it is an
# Ideas Discussion). Uses the workflow token, not anything from the plan.
_resolve_target() {
  local number="$1" query result
  read -r -d '' query <<'GRAPHQL' || true
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    discussion(number: $number) { id category { slug } }
  }
}
GRAPHQL
  result=$(gh_safe_graphql -f query="$query" \
    -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F number="$number" \
    --jq '.data.repository.discussion') || return 1
  mp_target_id "$result"
}

main() {
  local plan_path="${PLAN_PATH:?PLAN_PATH is required}"
  : "${REPO:?REPO is required}"
  local dry_run=0
  case "${CALLER_DRY_RUN:-0}" in 1 | true) dry_run=1 ;; esac
  local mode
  mode=$(mp_mode "${TARGET_DISCUSSION:-}" "${ENHANCE_BACKLOG:-}")

  if [[ ! -s "$plan_path" ]]; then
    echo "No Discussion mutations planned — nothing to publish."
    _summary "## Discussion mutations" "" "No mutations planned."
    return 0
  fi

  local target_id=""
  if [[ "$mode" = "single" ]]; then
    # GraphQL's Int is 32-bit signed.
    if ! [[ "$TARGET_DISCUSSION" =~ ^[1-9][0-9]{0,9}$ ]] || (( 10#$TARGET_DISCUSSION > 2147483647 )); then
      printf '::error::target_discussion must be a Discussion number, got: %s\n' \
        "$(printf '%s' "$TARGET_DISCUSSION" | tr '\n' ' ' | _neutralise)"
      return 1
    fi
    if ! target_id=$(_quiet_stderr _resolve_target "$TARGET_DISCUSSION"); then
      echo "::error::Could not look up Discussion #${TARGET_DISCUSSION}; nothing was published."
      return 1
    fi
    if [[ -z "$target_id" ]]; then
      echo "Discussion #${TARGET_DISCUSSION} is not in the ideas category — no comment may be posted."
    fi
  fi

  local context='{}'
  if [[ "$mode" != "single" ]]; then
    if ! context=$(_quiet_stderr _resolve_context "$plan_path"); then
      echo "::error::Could not resolve the repository, its Ideas category or the Discussions the plan names; nothing was published."
      return 1
    fi
  fi

  local plan errors_file
  errors_file=$(mktemp)
  if ! plan=$(mp_validate_plan "$plan_path" "$mode" "$target_id" "$context" 2>"$errors_file"); then
    local reasons
    reasons=$(_neutralise <"$errors_file")
    rm -f "$errors_file"
    echo "::error::Discussion mutation plan rejected (${mode} mode${TARGET_DISCUSSION:+, target #${TARGET_DISCUSSION}}); nothing was published."
    printf '%s\n' "$reasons"
    _summary "## ❌ Discussion mutation plan rejected" "" \
      "Mode: \`${mode}\`${TARGET_DISCUSSION:+, target #${TARGET_DISCUSSION}}. Nothing was published." "" \
      '```' "$reasons" '```'
    return 1
  fi
  rm -f "$errors_file"
  plan=$(mp_sanitise_plan "$plan")

  local count
  count=$(printf '%s' "$plan" | jq 'length')
  if [[ "$dry_run" -eq 1 ]]; then
    echo "dry run: ${count} planned mutation(s) validated (${mode} mode); nothing was written."
    _summary "## Discussion mutations (dry run)" "" \
      "${count} planned mutation(s) passed validation in \`${mode}\` mode. Nothing was written."
    return 0
  fi

  if [[ -z "${PUBLISH_LEDGER_OUT:-}" ]] \
    || ! mkdir -p "$(dirname -- "$PUBLISH_LEDGER_OUT")" || ! : >>"$PUBLISH_LEDGER_OUT"; then
    echo "::error::PUBLISH_LEDGER_OUT must name a writable file for the re-run ledger; nothing was published."
    return 1
  fi

  local plan_id done_ops
  if ! plan_id=$(_plan_id "$plan_path") \
    || ! done_ops=$(_quiet_stderr _resolve_done "$plan" "$plan_id" "$context"); then
    echo "::error::Could not check what an earlier attempt already published; nothing was published on this attempt."
    return 1
  fi

  # Live: the helpers must execute. DRY_RUN here is set by this script, not
  # inherited — the caller's preview flag was handled above.
  export DRY_RUN=0
  local planned='{}' skipped=0 entry index marker op kind resp id
  while IFS= read -r entry; do
    index=$(printf '%s' "$entry" | jq -r '.key')
    op=$(printf '%s' "$entry" | jq -c '.value')
    marker=$(mp_op_marker "$plan_id" "$index")
    kind=$(printf '%s' "$op" | jq -r '.op')
    case "$kind" in
      create_discussion)
        id=$(printf '%s' "$done_ops" | jq -r --arg i "$index" '.created[$i] // empty')
        if [[ -n "$id" ]]; then
          echo "already created ${id} on an earlier attempt"
          skipped=$((skipped + 1))
        else
          resp=$(create_discussion \
            "$(printf '%s' "$op" | jq -r '.repo_id')" \
            "$(printf '%s' "$op" | jq -r '.category_id')" \
            "$(printf '%s' "$op" | jq -r '.title')" \
            "$(printf '%s' "$op" | jq -r '.body')"$'\n\n'"$marker")
          _pace
          id=$(printf '%s' "$resp" | jq -r '.data.createDiscussion.discussion.id // empty')
          if [[ -z "$id" ]]; then
            echo "::error::createDiscussion returned no id"
            return 1
          fi
          _record "$plan_id" "$index" create_discussion "$id" || return 1
          echo "created Discussion ${id}"
        fi
        planned=$(printf '%s' "$planned" | jq -c \
          --arg k "$(printf '%s' "$op" | jq -r '.planned_id // empty')" --arg v "$id" \
          'if $k == "" then . else . + {($k): $v} end')
        ;;
      comment_on_discussion | add_label_to_discussion)
        id=$(printf '%s' "$op" | jq -r '.discussion_id')
        if [[ "$id" == planned-* ]]; then
          id=$(printf '%s' "$planned" | jq -r --arg k "$id" '.[$k] // empty')
        fi
        if [[ "$kind" = "comment_on_discussion" ]]; then
          if [[ "$(printf '%s' "$done_ops" | jq --arg i "$index" '.commented | index($i) != null')" = "true" ]]; then
            echo "already commented on ${id} on an earlier attempt"
            skipped=$((skipped + 1))
          else
            comment_on_discussion "$id" "$(printf '%s' "$op" | jq -r '.body')"$'\n\n'"$marker" >/dev/null
            _pace
            _record "$plan_id" "$index" comment_on_discussion "$id" || return 1
            echo "commented on ${id}"
          fi
        else
          add_label_to_discussion "$id" "$(printf '%s' "$op" | jq -r '.label_id')" >/dev/null
          _pace
          echo "labelled ${id}"
        fi
        ;;
    esac
  done < <(printf '%s' "$plan" | jq -c 'to_entries[]')

  _summary "## Discussion mutations" "" \
    "Published ${count} mutation(s) in \`${mode}\` mode (${skipped} already done by an earlier attempt)."
}

main "$@"
