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
#
# Exit: 0 published (or dry run / nothing to do); 1 plan rejected; other
# non-zero = a GitHub call failed (mutations before it stay applied).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-safe.sh
. "${SCRIPT_DIR}/lib/gh-safe.sh"
# shellcheck source=lib/mutation-plan.sh
. "${SCRIPT_DIR}/lib/mutation-plan.sh"
# shellcheck source=discussion-mutations.sh
. "${SCRIPT_DIR}/discussion-mutations.sh"

_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
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
    --jq '.data.repository.discussion')
  mp_target_id "$result"
}

main() {
  local plan_path="${PLAN_PATH:?PLAN_PATH is required}"
  local dry_run=0
  case "${CALLER_DRY_RUN:-0}" in 1 | true) dry_run=1 ;; esac
  local mode
  mode=$(mp_mode "${TARGET_DISCUSSION:-}" "${ENHANCE_BACKLOG:-}")

  if [ ! -s "$plan_path" ]; then
    echo "No Discussion mutations planned — nothing to publish."
    _summary "## Discussion mutations" "" "No mutations planned."
    return 0
  fi

  local target_id=""
  if [ "$mode" = "single" ]; then
    if ! [[ "$TARGET_DISCUSSION" =~ ^[1-9][0-9]{0,9}$ ]]; then
      echo "::error::target_discussion must be a Discussion number, got: ${TARGET_DISCUSSION}"
      return 1
    fi
    target_id=$(_resolve_target "$TARGET_DISCUSSION")
    if [ -z "$target_id" ]; then
      echo "Discussion #${TARGET_DISCUSSION} is not in the ideas category — no comment may be posted."
    fi
  fi

  local plan errors_file
  errors_file=$(mktemp)
  if ! plan=$(mp_validate_plan "$plan_path" "$mode" "$target_id" 2>"$errors_file"); then
    local reasons
    reasons=$(cat "$errors_file")
    rm -f "$errors_file"
    echo "::error::Discussion mutation plan rejected (${mode} mode${TARGET_DISCUSSION:+, target #${TARGET_DISCUSSION}}); nothing was published."
    printf '%s\n' "$reasons"
    _summary "## ❌ Discussion mutation plan rejected" "" \
      "Mode: \`${mode}\`${TARGET_DISCUSSION:+, target #${TARGET_DISCUSSION}}. Nothing was published." "" \
      '```' "$reasons" '```'
    return 1
  fi
  rm -f "$errors_file"

  local count
  count=$(printf '%s' "$plan" | jq 'length')
  if [ "$dry_run" -eq 1 ]; then
    echo "dry run: ${count} planned mutation(s) validated (${mode} mode); nothing was written."
    _summary "## Discussion mutations (dry run)" "" \
      "${count} planned mutation(s) passed validation in \`${mode}\` mode. Nothing was written."
    return 0
  fi

  # Live: the helpers must execute. DRY_RUN here is set by this script, not
  # inherited — the caller's preview flag was handled above.
  export DRY_RUN=0
  local planned='{}' op kind resp id
  while IFS= read -r op; do
    kind=$(printf '%s' "$op" | jq -r '.op')
    case "$kind" in
      create_discussion)
        resp=$(create_discussion \
          "$(printf '%s' "$op" | jq -r '.repo_id')" \
          "$(printf '%s' "$op" | jq -r '.category_id')" \
          "$(printf '%s' "$op" | jq -r '.title')" \
          "$(printf '%s' "$op" | jq -r '.body')")
        id=$(printf '%s' "$resp" | jq -r '.data.createDiscussion.discussion.id // empty')
        if [ -z "$id" ]; then
          echo "::error::createDiscussion returned no id"
          return 1
        fi
        planned=$(printf '%s' "$planned" | jq -c \
          --arg k "$(printf '%s' "$op" | jq -r '.planned_id // empty')" --arg v "$id" \
          'if $k == "" then . else . + {($k): $v} end')
        echo "created Discussion ${id}"
        ;;
      comment_on_discussion | add_label_to_discussion)
        id=$(printf '%s' "$op" | jq -r '.discussion_id')
        if [[ "$id" == planned-* ]]; then
          id=$(printf '%s' "$planned" | jq -r --arg k "$id" '.[$k] // empty')
        fi
        if [ "$kind" = "comment_on_discussion" ]; then
          comment_on_discussion "$id" "$(printf '%s' "$op" | jq -r '.body')" >/dev/null
          echo "commented on ${id}"
        else
          add_label_to_discussion "$id" "$(printf '%s' "$op" | jq -r '.label_id')" >/dev/null
          echo "labelled ${id}"
        fi
        ;;
    esac
  done < <(printf '%s' "$plan" | jq -c '.[]')

  _summary "## Discussion mutations" "" "Published ${count} mutation(s) in \`${mode}\` mode."
}

main "$@"
