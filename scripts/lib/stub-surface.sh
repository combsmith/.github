#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stub-surface.sh — single source of truth for caller-stub SURFACE drift.
#
# The centralized caller stubs (dev-lead + the RING reusables) are thin: their
# behavior lives in the reusable, so three surfaces are NOT repo-adjustable — the
# `on:` trigger set, the `permissions:` grants, and the (usually absent)
# `concurrency:` block. Both the compliance audit (`check_stub_surface_drift` in
# compliance-audit.sh) and the deploy sweep (`is_already_compliant` in
# deploy-standard-workflows.sh) must agree on what counts as surface drift,
# otherwise the audit flags a stub the sweep considers "already compliant" and
# never re-syncs — the finding recurs every cycle (#1236; same audit/deploy
# divergence class as #482 / #877). This file is sourced by both.
#
# These surfaces carry NO channel pin — the tier pin lives only on the
# jobs.<id>.uses / agent_ref lines. So the comparison is tier-invariant by
# construction: a stub that differs from the canonical ONLY by its correct tier
# channel pin has identical surfaces and is never flagged. This is the "explicit
# sub-checks" branch of #607 (vs a full-file byte guard, which would false-positive
# on the per-repo `with:` liberties agent-shield / feature-ideation document, and
# on feature-ideation's documented per-repo cron retune).
#
# The helpers below are PURE (args in, stdout out) and unit-tested by
# test/scripts/compliance-audit/stub-surface-drift.bats.
# ---------------------------------------------------------------------------

# Enrolled caller stubs and their guarded surfaces, as
# "workflow.yml:comma-separated-surfaces". Keep in lockstep with the RING list in
# compliance-audit.sh's check_centralized_workflow_stubs() and RING_REUSABLES in
# lib/ring-pins.sh. dev-lead's `permissions` / `concurrency` surfaces have
# dedicated, higher-signal checks in the audit's check_dev_lead_stub(), so only
# its `on:` surface is enrolled here.
readonly STUB_SURFACE_SHIMS=(
  "dev-lead.yml:on"
  "agent-shield.yml:on,permissions,concurrency"
  "auto-rebase.yml:on,permissions,concurrency"
  "dependency-audit.yml:on,permissions,concurrency"
  "dependabot-automerge.yml:on,permissions,concurrency"
  "dependabot-rebase.yml:on,permissions,concurrency"
  "pr-review-mention.yml:on,permissions,concurrency"
  "feature-ideation.yml:on,permissions,concurrency"
  "pr-auto-review.yml:on,permissions,concurrency"
  "persona-mention.yml:on,permissions"
)

# stub_guarded_surfaces <workflow.yml> -> the comma-separated surfaces guarded for
# this stub, or empty (status 1) if the workflow is not enrolled.
stub_guarded_surfaces() {
  local wf="$1" entry
  for entry in "${STUB_SURFACE_SHIMS[@]}"; do
    if [ "${entry%%:*}" = "$wf" ]; then
      printf '%s' "${entry#*:}"
      return 0
    fi
  done
  return 1
}

# stub_extract_blocks <content> <key> — print every YAML block whose key line, at
# ANY indentation, is `<indent><key>:`, including all lines indented deeper than
# the key line (the block body). A key can appear more than once (e.g. dev-lead's
# top-level `permissions: {}` plus its job-level `permissions:`), so all matches
# are concatenated in file order. Comment/blank lines inside a body are kept and
# stripped later by stub_normalize_surface; a `# concurrency:` comment never
# starts a block (the key must be the first non-space token).
stub_extract_blocks() {
  local content="$1" key="$2"
  printf '%s\n' "$content" | awk -v key="$key" '
    function indent(s,   n) { n = match(s, /[^ ]/); return n == 0 ? 0 : n - 1 }
    {
      if (capturing) {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { print; next }
        if (indent($0) > keyindent) { print; next }
        capturing = 0
      }
      if ($0 ~ ("^[[:space:]]*" key ":")) {
        capturing = 1; keyindent = indent($0); print; next
      }
    }
  '
}

# stub_normalize_surface — read a surface block on stdin and canonicalize it for
# comparison: strip trailing ` #…` inline comments (outside quotes) and whole-line comments, drop
# blank lines, and collapse two documented per-repo VALUES to placeholders:
#   • schedule cron VALUES — a repo MAY retune the cron without it counting as
#     trigger-surface drift (see feature-ideation.yml's header).
#   • pr-auto-review's `workflow_run.workflows:` list VALUE — a repo MUST name
#     its own CI workflow(s) here (see pr-auto-review.yml's header + TODO), so
#     the list value is not repo-locked while the `workflow_run` trigger key and
#     the rest of the `on:` surface stay verbatim-compared (#990). Both YAML list
#     forms are honored: the inline flow sequence `workflows: [ … ]` and the
#     block sequence (`workflows:` followed by deeper-indented `- …` entries) both
#     collapse to the same `workflows: WORKFLOWS` placeholder. Non-list shapes
#     (`null`, a bare scalar, or an empty list with no entries) are left intact so
#     they still count as drift.
# `workflows:` is a key only under `workflow_run`, which appears in no other
# guarded surface, so the collapse is safe to apply unconditionally. Pure:
# stdin -> stdout.
stub_normalize_surface() {
  tr -d '\r' \
    | awk '
        # Strip a YAML comment (` #…` or a whole-line `#…`) only OUTSIDE quoted
        # scalars, so `branches: ["release #1"]` keeps its `#1`.
        {
          out = ""; q = ""; n = length($0)
          for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (q != "") { if (c == q) q = ""; out = out c; continue }
            if (c == "\"" || c == "\047") { q = c; out = out c; continue }
            if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[[:space:]]/)) break
            out = out c
          }
          sub(/[[:space:]]+$/, "", out)
          print out
        }
      ' \
    | sed -E \
        -e 's/(- cron:[[:space:]]*).*/\1CRON/' \
    | awk '
        function flush() {
          if (pending) { if (saw_item) printf "%sworkflows: WORKFLOWS\n", ind; else print saved; pending = 0 }
        }
        function indent(s,   n) { n = match(s, /[^ ]/); return n == 0 ? 0 : n - 1 }
        {
          if (pending) {
            if ($0 ~ /^[[:space:]]*$/) { next }
            # collapse a block sequence: deeper-indented "- …" entries belong to
            # the deferred workflows: line; anything else ends the block.
            if (indent($0) > wfindent && $0 ~ /^[[:space:]]*-[[:space:]]+/) {
              saw_item = 1; next
            }
            flush()
          }
          if ($0 ~ /^[[:space:]]*workflows:[[:space:]]*/) {
            val = $0; sub(/^[[:space:]]*workflows:[[:space:]]*/, "", val)
            wfindent = indent($0); ind = substr($0, 1, wfindent)
            if (val ~ /^\[/ && val !~ /^\[[[:space:]]*\]/) { printf "%sworkflows: WORKFLOWS\n", ind; next }
            if (val == "")  { pending = 1; saw_item = 0; saved = $0; next }
            print; next          # null / bare scalar — leave intact (drift)
          }
          print
        }
        END { flush() }
      ' \
    | grep -vE '^[[:space:]]*$' || true
}

# stub_surface_drift <canonical> <deployed> <key> — return 0 (success) when the
# given surface has DRIFTED between the canonical template and the deployed stub,
# 1 when it is clean. Success-means-drift so `if stub_surface_drift …; then
# add_finding …; fi` reads naturally.
stub_surface_drift() {
  local canonical="$1" deployed="$2" key="$3" c d
  c="$(stub_extract_blocks "$canonical" "$key" | stub_normalize_surface)"
  d="$(stub_extract_blocks "$deployed" "$key" | stub_normalize_surface)"
  [ "$c" = "$d" ] && return 1 || return 0
}

# stub_any_surface_drift <workflow.yml> <canonical> <deployed> — return 0 when ANY
# guarded surface of an enrolled stub has drifted, 1 when all are clean or the
# workflow is not enrolled. The deploy sweep's single-call entry point.
stub_any_surface_drift() {
  local wf="$1" canonical="$2" deployed="$3" surfaces surface
  local -a surface_list
  surfaces="$(stub_guarded_surfaces "$wf")" || return 1
  local old_ifs="$IFS"
  IFS=,
  # shellcheck disable=SC2206  # intentional comma split of a fixed internal list
  surface_list=($surfaces)
  IFS="$old_ifs"
  for surface in "${surface_list[@]}"; do
    stub_surface_drift "$canonical" "$deployed" "$surface" && return 0
  done
  return 1
}
