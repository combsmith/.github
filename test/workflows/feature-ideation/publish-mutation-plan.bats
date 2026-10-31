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
# lookup reads .data.repository.discussion; the context lookup reads
# .data.repository.{id,discussionCategories} and .data.nodes; create reads
# .data.createDiscussion.discussion.id; comment/label only need non-null data.
# Discussions: D_target/D_existing/D_a/D_b are Ideas in this repo (R_1),
# D_annc is an Announcement in this repo, D_foreign is an Idea elsewhere.
CATS_IDEAS='[{"id":"C_ideas","slug":"ideas","name":"Ideas"},{"id":"C_ann","slug":"announcements","name":"Announcements"},{"id":"C_general","slug":"general","name":"General"}]'
NODES='[{"id":"D_target","category":{"id":"C_ideas"},"repository":{"id":"R_1"}},{"id":"D_existing","category":{"id":"C_ideas"},"repository":{"id":"R_1"}},{"id":"D_a","category":{"id":"C_ideas"},"repository":{"id":"R_1"}},{"id":"D_b","category":{"id":"C_ideas"},"repository":{"id":"R_1"}},{"id":"D_annc","category":{"id":"C_ann"},"repository":{"id":"R_1"}},{"id":"D_foreign","category":{"id":"C_ideas"},"repository":{"id":"R_other"}}]'
# response <categories-json> — the universal stub response.
response() {
  jq -nc --argjson cats "$1" --argjson nodes "$NODES" '{data: {
    repository: {id: "R_1", discussionCategories: {nodes: $cats},
                 discussion: {id: "D_target", category: {slug: "ideas"}}},
    nodes: $nodes,
    createDiscussion: {discussion: {id: "D_new", number: 7, url: "https://x"}},
    addDiscussionComment: {comment: {id: "C_1"}}}}'
}
OK_RESPONSE="$(response "$CATS_IDEAS")"

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  # Wrap the stub so request bodies sent on stdin (labels, node lookups) are
  # captured too: GH_STDIN_LOG gets one JSON document per such call.
  export GH_STDIN_LOG="${TT_TMP}/stdin.log"
  local stub_dir="${TT_TMP}/bin"
  mv "$stub_dir/gh" "$stub_dir/gh-real"
  cat >"$stub_dir/gh" <<EOF
#!/usr/bin/env bash
if [ "\${!#}" = "-" ]; then cat >>"$GH_STDIN_LOG"; printf '\n' >>"$GH_STDIN_LOG"; fi
exec "$stub_dir/gh-real" "\$@"
EOF
  chmod +x "$stub_dir/gh"
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

# How many gh calls carried a mutation of the given name (argv or stdin body).
mutations() {
  local n=0 m
  for f in "$GH_STUB_LOG" "$GH_STDIN_LOG"; do
    [ -f "$f" ] || continue
    m=$(grep -c -e "$1" "$f" || true)
    n=$((n + m))
  done
  echo "$n"
}

# No Discussion was created, commented on or labelled.
no_writes() {
  [ "$(mutations createDiscussion)" -eq 0 ] &&
    [ "$(mutations addDiscussionComment)" -eq 0 ] &&
    [ "$(mutations addLabelsToLabelable)" -eq 0 ]
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
  [ "$(mutations addLabelsToLabelable)" -eq 0 ]
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
  no_writes
}

@test "dry run: DRY_RUN=0 in the environment does not override the caller's dry run" {
  export CALLER_DRY_RUN=1
  export DRY_RUN=0
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ]
  no_writes
}

@test "dry run: CALLER_DRY_RUN=true is a dry run too" {
  export CALLER_DRY_RUN=true
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ]
  no_writes
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
  plan_add "$(create planned-discussion-1)"
  plan_add "$(label planned-discussion-1)"
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations createDiscussion)" -eq 1 ]
  [ "$(mutations addDiscussionComment)" -eq 1 ]
  # The planned id was resolved to the id GitHub returned for the create.
  [ "$(mutations addLabelsToLabelable)" -eq 1 ]
  jq -se '[.[] | select(.query | contains("addLabelsToLabelable"))] | .[0].variables.labelableId == "D_new"' "$GH_STDIN_LOG" >/dev/null
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
  no_writes
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
  no_writes
}

@test "plan: an unknown op rejects the plan" {
  plan_add '{"op":"delete_discussion","discussion_id":"D_a"}'
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown op"* ]]
  no_writes
}

@test "plan: an entry missing a required field rejects the plan" {
  plan_add '{"op":"comment_on_discussion","discussion_id":"D_a"}'
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
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
# Review follow-up: category, repository and volume limits (#1389)
# ---------------------------------------------------------------------------

@test "scheduled: a create in a category other than Ideas is rejected" {
  plan_add "$(jq -nc '{op:"create_discussion",repo_id:"R_1",category_id:"C_ann",title:"t",body:"b"}')"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the Ideas category"* ]]
  no_writes
}

@test "scheduled: a create with another repository's id is rejected" {
  plan_add "$(jq -nc '{op:"create_discussion",repo_id:"R_other",category_id:"C_ideas",title:"t",body:"b"}')"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not this repository"* ]]
  no_writes
}

@test "scheduled: with no Ideas category, creates go to General (the prompt's fallback) and nowhere else" {
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(response '[{"id":"C_ann","slug":"announcements","name":"Announcements"},{"id":"C_general","slug":"general","name":"General"}]')"
  plan_add "$(jq -nc '{op:"create_discussion",repo_id:"R_1",category_id:"C_general",title:"t",body:"b"}')"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations createDiscussion)" -eq 1 ]

  rm -f "$PLAN_PATH" "$GH_STUB_LOG" "$GH_STDIN_LOG"
  plan_add "$(jq -nc '{op:"create_discussion",repo_id:"R_1",category_id:"C_ann",title:"t",body:"b"}')"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
}

@test "scheduled: a comment on a Discussion outside the Ideas category is rejected" {
  plan_add "$(comment D_existing)"
  plan_add "$(comment D_annc)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"D_annc" is not a Discussion in the Ideas category'* ]]
  no_writes
}

@test "scheduled: a label on a Discussion outside the Ideas category is rejected" {
  plan_add "$(label D_annc)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
}

@test "scheduled: a comment on another repository's Discussion, or an unknown id, is rejected" {
  plan_add "$(comment D_foreign)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
  rm -f "$PLAN_PATH"
  plan_add "$(comment D_nowhere)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
}

@test "backlog: a comment on a Discussion outside the Ideas category is rejected" {
  export ENHANCE_BACKLOG=1
  plan_add "$(comment D_a)"
  plan_add "$(comment D_annc)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
}

@test "backlog: more than 50 comments in one run is rejected" {
  export ENHANCE_BACKLOG=1
  local i
  for i in $(seq 1 50); do plan_add "$(comment D_a)"; done
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations addDiscussionComment)" -eq 50 ]

  rm -f "$GH_STUB_LOG" "$GH_STDIN_LOG"
  plan_add "$(comment D_a)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most 50 comments"* ]]
  no_writes
}

@test "scheduled: more than 5 labels in one run is rejected" {
  local i
  for i in 1 2 3 4 5 6; do plan_add "$(label D_existing)"; done
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most 5 labels"* ]]
  no_writes
}

@test "scheduled: if the repository/category lookup fails, nothing is published" {
  export GH_STUB_EXIT=1
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not resolve"* ]]
  no_writes
}

@test "scheduled: the plan's ids are only looked up, the lookup uses the workflow token's view" {
  plan_add "$(comment D_existing)"
  run "$EXEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # One node lookup carrying exactly the plan's existing ids.
  jq -se '[.[] | select(.query | contains("nodes(ids"))] | length == 1 and .[0].variables.ids == ["D_existing"]' "$GH_STDIN_LOG" >/dev/null
}

# ---------------------------------------------------------------------------
# Review follow-up: model text in rejection reasons is neutralised (#1389)
# ---------------------------------------------------------------------------

@test "reasons: a model-supplied id cannot inject a workflow command or break the summary fence" {
  export GITHUB_STEP_SUMMARY="${TT_TMP}/summary.md"
  local evil
  evil=$(printf 'planned-x\n::error::injected\n```\n# heading')
  plan_add "$(jq -nc --arg d "$evil" '{op:"add_label_to_discussion",discussion_id:$d,label_id:"L"}')"
  plan_add "$(jq -nc --arg d "$evil" '{op:"create_discussion",repo_id:"R_1",category_id:"C_ideas",title:"t",body:"b",planned_id:$d}')"
  run "$EXEC"
  [ "$status" -ne 0 ]
  no_writes
  # No output line is a workflow command other than the executor's own error.
  ! grep -E '^[[:space:]]*::' <<< "$output" | grep -v '^::error::Discussion mutation plan rejected'
  ! grep -q 'injected' <<< "$(grep -E '^[[:space:]]*::' <<< "$output")"
  # The summary has exactly the executor's two fence lines and no other backticks.
  [ "$(grep -c '^```$' "$GITHUB_STEP_SUMMARY")" -eq 2 ]
  [ "$(grep -c '`' "$GITHUB_STEP_SUMMARY")" -eq 3 ]  # 2 fences + the `scheduled` mode word
  ! grep -qE '^[[:space:]]*::' "$GITHUB_STEP_SUMMARY"
}

@test "reasons: every model-supplied value in a reason is JSON-quoted" {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/mutation-plan.sh"
  plan_add "$(jq -nc '{op:"add_label_to_discussion",discussion_id:"planned-a\nb",label_id:"L"}')"
  run --separate-stderr mp_validate_plan "$PLAN_PATH" scheduled "" '{}'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *'"planned-a\nb" is not created earlier in this plan'* ]]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
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
