#!/usr/bin/env bash
# mutation-plan.sh — pure validation of the Discussion mutation plan (#1389).
#
# Why this exists:
#   The analyst (Mary) runs Claude Code with the Bash tool. Anything in her
#   job's environment — the token, DRY_RUN, TARGET_DISCUSSION — is reachable
#   and changeable from that shell, so a policy checked there is advisory. So
#   the model job only RECORDS mutations (discussion-mutations.sh with
#   DRY_RUN=1, a JSONL plan) using a read-only token, and the model-free
#   `publish` job validates the plan here against the CALLER's inputs before
#   executing it. The plan is model output: treat every field as untrusted.
#
# Functions:
#   mp_mode <target_discussion> <enhance_backlog>
#       → single | backlog | scheduled  (same precedence as the prompt)
#   mp_target_id <discussion-json>
#       → the node id of a Discussion lookup result when it is in the `ideas`
#         category, else empty (no comment can match an empty target)
#   mp_ideation_category <categories-json>
#       → the id of the category ideation writes to: the one with slug `ideas`
#         (or name `Ideas`), else `general` — the same fallback the prompt
#         gives the model (Phase 7). Empty when neither exists.
#   mp_existing_targets <plan.jsonl>
#       → JSON array of the distinct discussion_ids the plan names that are
#         NOT planned-discussion-N references (the executor resolves these)
#   mp_validate_plan <plan.jsonl> <mode> [target_node_id] [context-json]
#       → stdout: the plan as one compact JSON array; rc 0
#         stderr: one line per reason the plan is rejected; rc 1
#         rc 64 on bad usage. A plan is all-or-nothing: one bad entry rejects
#         every entry, so a manipulated plan publishes nothing.
#       context (resolved by the executor with the workflow token, never read
#       from the plan; used in backlog and scheduled modes):
#         {"repo_id": "<this repo's node id>",
#          "category_id": "<mp_ideation_category>",
#          "target_categories": {"<discussion node id>": "<its category id>"}}
#       target_categories lists only Discussions of THIS repository. Missing
#       context fails closed: nothing can match an absent id.
#
# Rules (by mode):
#   single     only comment_on_discussion, at most 1, and its discussion_id
#              must equal target_node_id (resolved from the caller's number)
#   backlog    only comment_on_discussion
#   scheduled  create_discussion (at most MP_MAX_CREATES), comment, label
#   backlog and scheduled
#              a create must use this repo's id and the ideation category; a
#              comment or label on an existing Discussion needs one in the
#              ideation category of this repo; at most MP_MAX_COMMENTS
#              comments and MP_MAX_LABELS labels per run
#   all        known op, required fields are non-empty strings; a
#              discussion_id of the form planned-discussion-N must name a
#              planned_id of an EARLIER create_discussion in the same plan;
#              planned_ids are unique and of that form.
#   Every model-supplied value in a reason is JSON-quoted (tojson), so a
#   reason is one line with no raw model text.

set -euo pipefail

MP_MAX_CREATES=5
# Comments per run. The prompt asks for at most this many (backlog: one per
# candidate, the rest next run; scheduled: updates to matched ideas plus
# retirement notes, which the 100-idea signals window bounds far below this).
MP_MAX_COMMENTS=50
# Labels per run: one `enhancement` label per new Discussion.
MP_MAX_LABELS=5

mp_mode() {
  local target="${1:-}" backlog="${2:-}"
  if [ -n "$target" ]; then
    printf 'single'
  elif [ "$backlog" = "1" ] || [ "$backlog" = "true" ]; then
    printf 'backlog'
  else
    printf 'scheduled'
  fi
}

mp_target_id() {
  printf '%s' "${1:-}" | jq -r '
    if type == "object" and (.category.slug // "") == "ideas" and ((.id // "") | type) == "string"
    then .id else "" end' 2>/dev/null || true
}

mp_ideation_category() {
  printf '%s' "${1:-}" | jq -r '
    if type != "array" then "" else
      ([.[] | objects | select(.slug == "ideas" or .name == "Ideas")][0].id
       // [.[] | objects | select(.slug == "general")][0].id // "")
    end' 2>/dev/null || true
}

mp_existing_targets() {
  jq -cs '[.[] | objects | .discussion_id | strings
           | select(test("^planned-") | not)] | unique' "$1" 2>/dev/null || printf '[]'
}

mp_validate_plan() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    printf '[mutation-plan] usage: mp_validate_plan <plan.jsonl> <mode> [target_node_id] [context-json]\n' >&2
    return 64
  fi
  local plan="$1" mode="$2" target="${3:-}" context="${4:-}"
  [ -n "$context" ] || context='{}'
  if ! printf '%s' "$context" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '[mutation-plan] context must be a JSON object\n' >&2
    return 64
  fi
  case "$mode" in
    single | backlog | scheduled) ;;
    *)
      printf '[mutation-plan] unknown mode: %s\n' "$mode" >&2
      return 64
      ;;
  esac
  if [ ! -f "$plan" ]; then
    printf '[mutation-plan] plan file not found: %s\n' "$plan" >&2
    return 64
  fi

  local ops
  if ! ops=$(jq -cs '.' "$plan" 2>/dev/null); then
    printf 'plan is not valid JSONL (one JSON object per line)\n' >&2
    return 1
  fi

  local verdict
  verdict=$(printf '%s' "$ops" | jq -c \
    --arg mode "$mode" --arg target "$target" --argjson max "$MP_MAX_CREATES" \
    --argjson max_comments "$MP_MAX_COMMENTS" --argjson max_labels "$MP_MAX_LABELS" \
    --argjson ctx "$context" '
    def nonempty: type == "string" and length > 0;
    def fields:
      {create_discussion: ["repo_id", "category_id", "title", "body"],
       comment_on_discussion: ["discussion_id", "body"],
       add_label_to_discussion: ["discussion_id", "label_id"]}[.];
    def allowed:
      {single: ["comment_on_discussion"],
       backlog: ["comment_on_discussion"],
       scheduled: ["create_discussion", "comment_on_discussion", "add_label_to_discussion"]}[$mode];
    def planned_ref: type == "string" and test("^planned-discussion-[0-9]+$");
    . as $ops
    | reduce range(0; $ops | length) as $i (
        {errors: [], planned: [], creates: 0, comments: 0, labels: 0};
        $ops[$i] as $o | "entry \($i + 1)" as $at
        | if ($o | type) != "object" then
            .errors += ["\($at): not a JSON object"]
          elif (($o.op | type) != "string") or (($o.op | fields) == null) then
            .errors += ["\($at): unknown op \($o.op | tojson)"]
          elif ([($o.op | fields)[] as $f | $o[$f] | nonempty] | all | not) then
            .errors += ["\($at): \($o.op) needs non-empty string fields \($o.op | fields | join(", "))"]
          elif ([allowed[] | . == $o.op] | any | not) then
            .errors += ["\($at): \($o.op) is not allowed in \(if $mode == "single" then "single-idea" else $mode end) mode"]
          elif $o.op == "create_discussion" then
            .creates += 1
            | if .creates > $max then
                .errors += ["\($at): a run may create at most \($max) Discussions"]
              elif ($ctx.repo_id | nonempty | not) or $o.repo_id != $ctx.repo_id then
                .errors += ["\($at): repo_id \($o.repo_id | tojson) is not this repository"]
              elif ($ctx.category_id | nonempty | not) or $o.category_id != $ctx.category_id then
                .errors += ["\($at): category_id \($o.category_id | tojson) is not the Ideas category"]
              else . end
            | if ($o | has("planned_id")) then
                if ($o.planned_id | planned_ref | not) then
                  .errors += ["\($at): planned_id must look like planned-discussion-N"]
                elif ([.planned[] | . == $o.planned_id] | any) then
                  .errors += ["\($at): duplicate planned_id \($o.planned_id | tojson)"]
                else .planned += [$o.planned_id] end
              else . end
          else
            (if $o.op == "comment_on_discussion" then .comments += 1 else .labels += 1 end)
            | ($o.discussion_id | startswith("planned-")) as $is_planned
            | if $mode == "single" and $o.discussion_id != $target then
                .errors += ["\($at): \($o.discussion_id | tojson) is not the target Discussion"]
              elif $mode == "single" and .comments > 1 then
                .errors += ["\($at): single-idea mode posts exactly one comment"]
              elif .comments > $max_comments then
                .errors += ["\($at): a run may post at most \($max_comments) comments"]
              elif .labels > $max_labels then
                .errors += ["\($at): a run may add at most \($max_labels) labels"]
              elif $is_planned and ([.planned[] | . == $o.discussion_id] | any | not) then
                .errors += ["\($at): \($o.discussion_id | tojson) is not created earlier in this plan"]
              elif $mode != "single" and ($is_planned | not)
                   and (($ctx.category_id | nonempty | not)
                        or (($ctx.target_categories // {})[$o.discussion_id] != $ctx.category_id)) then
                .errors += ["\($at): \($o.discussion_id | tojson) is not a Discussion in the Ideas category of this repository"]
              else . end
          end)
    | if (.errors | length) > 0 then {ok: false, errors: .errors} else {ok: true, ops: $ops} end')

  if [ "$(printf '%s' "$verdict" | jq -r '.ok')" = "true" ]; then
    printf '%s' "$verdict" | jq -c '.ops'
    return 0
  fi
  printf '%s' "$verdict" | jq -r '.errors[]' >&2
  return 1
}
