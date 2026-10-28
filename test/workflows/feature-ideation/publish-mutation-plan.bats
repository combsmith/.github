#!/usr/bin/env bats
# Tests for publish-mutation-plan.sh and lib/mutation-plan.sh (#1389).
#
# The analyst (model) job only records Discussion mutations into a JSONL plan.
# This executor runs in the separate, model-free `publish` job: it validates the
# plan against the CALLER's inputs (dry_run, target_discussion,
# enhance_backlog) and only then performs it. These tests prove that a plan
# the model could have written cannot reach a write the caller did not allow.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

EXEC="${TT_SCRIPTS_DIR}/publish-mutation-plan.sh"

# One response that satisfies every call the executor can make: the target
# lookup reads .data.repository.discussion, create reads
# .data.createDiscussion.discussion.id; comment/label only need non-null data.
OK_RESPONSE='{"data":{"repository":{"discussion":{"id":"D_target","category":{"slug":"ideas"}}},"createDiscussion":{"discussion":{"id":"D_new","number":7,"url":"https://x"}},"addDiscussionComment":{"comment":{"id":"C_1"}}}}'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  export GH_STUB_STDOUT="$OK_RESPONSE"
  export PLAN_PATH="${TT_TMP}/plan.jsonl"
  export REPO="octo/repo"
  export GH_TOKEN="test-token"
  export CALLER_DRY_RUN=0
  export TARGET_DISCUSSION=""
  export ENHANCE_BACKLOG=0
  unset DRY_RUN GITHUB_STEP_SUMMARY
}

teardown() {
  tt_cleanup_tmpdir
}

# plan_add <json-object> — append one plan entry.
plan_add() { printf '%s\n' "$1" >>"$PLAN_PATH"; }

comment() { jq -nc --arg d "$1" '{op:"comment_on_discussion",discussion_id:$d,body:"<!-- feature-ideation:enhanced -->\nbody"}'; }
create() { jq -nc --arg p "${1:-}" '{op:"create_discussion",repo_id:"R_1",category_id:"C_ideas",title:"💡 t",body:"b"} + (if $p == "" then {} else {planned_id:$p} end)'; }
label() { jq -nc --arg d "$1" '{op:"add_label_to_discussion",discussion_id:$d,label_id:"L_enh"}'; }

# How many gh calls carried a mutation of the given name.
mutations() {
  [ -f "$GH_STUB_LOG" ] || { echo 0; return; }
  grep -c -e "$1" "$GH_STUB_LOG" || true
}

# ---------------------------------------------------------------------------
# Single-idea mode: only one comment, only on the caller's target
# ---------------------------------------------------------------------------

@test "single-idea: a comment on a Discussion other than the target is rejected and nothing is written" {
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_other)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the target Discussion"* ]]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

@test "single-idea: one comment on the target is posted" {
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_target)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations addDiscussionComment)" -eq 1 ]
  grep addDiscussionComment "$GH_STUB_LOG" | grep -q 'discussionId=D_target'
  # The target was looked up by the caller's number, not taken from the plan.
  grep -q 'number=12' "$GH_STUB_LOG"
}

@test "single-idea: an off-target comment hidden after a valid one rejects the whole plan" {
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_target)"
  plan_add "$(comment D_other)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

@test "single-idea: creating a Discussion is rejected" {
  export TARGET_DISCUSSION=12
  plan_add "$(create)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not allowed in single-idea mode"* ]]
  [ "$(mutations createDiscussion)" -eq 0 ]
}

@test "single-idea: labelling is rejected" {
  export TARGET_DISCUSSION=12
  plan_add "$(label D_target)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations --input)" -eq 0 ]
}

@test "single-idea: a second comment on the target is rejected" {
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_target)"
  plan_add "$(comment D_target)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

@test "single-idea: a target outside the ideas category accepts no comment" {
  export TARGET_DISCUSSION=12
  export GH_STUB_STDOUT='{"data":{"repository":{"discussion":{"id":"D_target","category":{"slug":"general"}}}}}'
  plan_add "$(comment D_target)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

@test "single-idea: a non-numeric target is refused before any API call" {
  export TARGET_DISCUSSION='12) { id } x: repository(owner:"a"'
  plan_add "$(comment D_target)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

# ---------------------------------------------------------------------------
# dry_run: the caller's preview flag is honoured outside the model
# ---------------------------------------------------------------------------

@test "dry run: a valid plan is validated but nothing is written" {
  export CALLER_DRY_RUN=1
  plan_add "$(create planned-discussion-1)"
  plan_add "$(label planned-discussion-1)"
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"dry run"* ]]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "dry run: DRY_RUN=0 in the environment does not override the caller's dry run" {
  export CALLER_DRY_RUN=1
  export DRY_RUN=0
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "dry run: CALLER_DRY_RUN=true is a dry run too" {
  export CALLER_DRY_RUN=true
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "dry run: single-idea validation still runs, so an off-target plan fails the preview" {
  export CALLER_DRY_RUN=1
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_other)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Scheduled ideation
# ---------------------------------------------------------------------------

@test "scheduled: creates, comments and a label on a planned Discussion are executed in order" {
  local stub_dir="${TT_TMP}/bin" bodies="${TT_TMP}/stdin.log"
  # Wrap the stub so request bodies sent on stdin (labels) are captured too.
  mv "$stub_dir/gh" "$stub_dir/gh-real"
  cat >"$stub_dir/gh" <<EOF
#!/usr/bin/env bash
if [ "\${*: -1}" = "-" ]; then cat >>"$bodies"; printf '\n' >>"$bodies"; fi
exec "$stub_dir/gh-real" "\$@"
EOF
  chmod +x "$stub_dir/gh"
  plan_add "$(create planned-discussion-1)"
  plan_add "$(label planned-discussion-1)"
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations createDiscussion)" -eq 1 ]
  [ "$(mutations addDiscussionComment)" -eq 1 ]
  # The planned id was resolved to the id GitHub returned for the create.
  jq -e '.variables.labelableId == "D_new"' "$bodies" >/dev/null
}

@test "scheduled: more than 5 new Discussions is rejected" {
  local i
  for i in 1 2 3 4 5 6; do plan_add "$(create "planned-discussion-$i")"; done
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most 5"* ]]
  [ "$(mutations createDiscussion)" -eq 0 ]
}

@test "scheduled: a label on an unknown planned Discussion is rejected" {
  plan_add "$(create planned-discussion-1)"
  plan_add "$(label planned-discussion-9)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations createDiscussion)" -eq 0 ]
}

@test "scheduled: duplicate planned ids are rejected" {
  plan_add "$(create planned-discussion-1)"
  plan_add "$(create planned-discussion-1)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations createDiscussion)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Backlog mode
# ---------------------------------------------------------------------------

@test "backlog: comments are posted, creating a Discussion is rejected" {
  export ENHANCE_BACKLOG=1
  plan_add "$(comment D_a)"
  plan_add "$(comment D_b)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations addDiscussionComment)" -eq 2 ]

  rm -f "$PLAN_PATH" "$GH_STUB_LOG"
  plan_add "$(comment D_a)"
  plan_add "$(create)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "backlog: target_discussion wins over enhance_backlog (single-idea rules apply)" {
  export ENHANCE_BACKLOG=1
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_a)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ "$(mutations addDiscussionComment)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Plan shape
# ---------------------------------------------------------------------------

@test "plan: a missing or empty plan publishes nothing and succeeds" {
  run "$EXEC"
  [ "$status" -eq 0 ]
  [ ! -f "$GH_STUB_LOG" ]
  : >"$PLAN_PATH"
  run "$EXEC"
  [ "$status" -eq 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "plan: a line that is not JSON rejects the plan" {
  plan_add "$(comment D_a)"
  plan_add 'not json'
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "plan: an unknown op rejects the plan" {
  plan_add '{"op":"delete_discussion","discussion_id":"D_a"}'
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown op"* ]]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "plan: an entry missing a required field rejects the plan" {
  plan_add '{"op":"comment_on_discussion","discussion_id":"D_a"}'
  run "$EXEC"
  [ "$status" -ne 0 ]
  [ ! -f "$GH_STUB_LOG" ]
}

@test "plan: rejection reasons reach the step summary" {
  export GITHUB_STEP_SUMMARY="${TT_TMP}/summary.md"
  export TARGET_DISCUSSION=12
  plan_add "$(comment D_other)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  grep -q "not the target Discussion" "$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------------------
# lib/mutation-plan.sh — mode resolution
# ---------------------------------------------------------------------------

@test "mp_mode: target wins, then backlog, else scheduled" {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/mutation-plan.sh"
  [ "$(mp_mode 12 1)" = "single" ]
  [ "$(mp_mode 12 0)" = "single" ]
  [ "$(mp_mode '' 1)" = "backlog" ]
  [ "$(mp_mode '' true)" = "backlog" ]
  [ "$(mp_mode '' 0)" = "scheduled" ]
  [ "$(mp_mode '' '')" = "scheduled" ]
}
