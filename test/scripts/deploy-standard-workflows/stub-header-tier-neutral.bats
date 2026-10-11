#!/usr/bin/env bats
# Issue #1297 — a synced stub's header never contradicts its own `uses:` pin.
#
# The sweep re-pins a ring-managed stub's `uses:` / `agent_ref:` / `checkout_ref:`
# lines to the repo's ring channel (ring_repin_uses) but deploys the comments
# verbatim. A template header naming `<agent>/v<N>-stable` therefore sits above a
# `@<agent>/v<N>-ring1` pin in every ring repo, review bots flag the mismatch, and
# agent passes "fix" it in the consumer — drifting the stub from the template.
# The headers are tier-neutral instead, so:
#   - no ring-managed template, rendered at a ring channel, still names the
#     agent's stable channel anywhere;
#   - a correctly swept ring-1 stub is still compliant (stub_body_matches_template).

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/hdr.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh: serves v1 channel tags for every agent (matching-refs); nothing else.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *matching-refs/tags/*)
      agent="${2##*matching-refs/tags/}"; agent="${agent%%/*}"
      for c in stable next ring0 ring1; do echo "refs/tags/${agent}/v1-${c}"; done
      exit 0 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# ring_rendered_templates — for every ring-managed channel-pinned template, print
# "<template>\t<base>\t<ring1-ref>": the ring1 ref keeps the template's own major.
ring_rendered_templates() {
  bash -c '
    source "$1"
    for t in "$2"/standards/workflows/*.yml; do
      base="$(reusable_base_of "$t")"
      [ -n "$base" ] && ring_is_ring_reusable "$base" || continue
      ref="$(reusable_uses_of "$t")"; ref="${ref##*@}"
      [[ "$ref" =~ ^${base}/v([0-9]+)-stable$ ]] || continue
      printf "%s\t%s\t%s\n" "$t" "$base" "${base}/v${BASH_REMATCH[1]}-ring1"
    done
  ' _ "$SCRIPT" "$REPO_ROOT"
}

@test "fixture: the channel-pinned templates are enumerated" {
  run ring_rendered_templates
  [ "$status" -eq 0 ]
  local n
  n="$(grep -c . <<< "$output")"
  [ "$n" -ge 10 ]
  grep -qF 'persona-mention.yml' <<< "$output"
  grep -qF 'pr-review.yml' <<< "$output"
}

@test "every ring-managed template, rendered at ring1, names no stable channel for its agent" {
  local rows t base ref rendered bad=""
  rows="$(ring_rendered_templates)"
  while IFS=$'\t' read -r t base ref; do
    rendered="$(bash -c 'source "$1"; ring_repin_uses "$2" "$3" < "$4"' _ "$SCRIPT" "$base" "$ref" "$t")"
    # The pin itself moved…
    grep -qF "@${ref}" <<< "$rendered" || bad+="${t##*/}: pin not re-pinned"$'\n'
    # …and nothing else in the stub still names the agent's stable channel.
    if grep -nE "${base}/(v[0-9]+-)?stable|${base} stable channel" <<< "$rendered" >"$TT_TMP/hits"; then
      bad+="${t##*/}: $(tr '\n' ' ' < "$TT_TMP/hits")"$'\n'
    fi
  done <<< "$rows"
  if [ -n "$bad" ]; then printf '%s' "$bad"; return 1; fi
}

@test "sweep: every ring-managed template's existing stubs with stale headers are flagged as non-compliant (not skipped)" {
  install_gh_stub
  local rows t base ref rendered old bad=""
  rows="$(ring_rendered_templates)"
  while IFS=$'\t' read -r t base ref; do
    rendered="$(bash -c 'source "$1"; ring_repin_uses "$2" "$3" < "$4"' _ "$SCRIPT" "$base" "$ref" "$t")"
    # Simulate an existing ring-1 stub that still carries the old stable-channel header
    old="$(printf '# pinned to the \`%s/v1-stable\` channel\n%s\n' "$base" "$rendered")"
    # Verify it is NOT compliant (would be processed, not skipped, by the sweep)
    run bash -c 'source "$1"; is_already_compliant "$2" "$3" petry-projects/test-repo' _ "$SCRIPT" "$old" "$t"
    [ "$status" -eq 1 ] || bad+="${t##*/}: stale header not flagged as non-compliant"$'\n'
  done <<< "$rows"
  if [ -n "$bad" ]; then printf '%s' "$bad"; return 1; fi
}

@test "ring-1 repo: a correctly swept persona-mention stub is compliant and its header agrees with its pin" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/persona-mention.yml" swept
  swept="$(bash -c 'source "$1"; ring_repin_uses persona-mention persona-mention/v1-ring1 < "$2"' _ "$SCRIPT" "$t")"
  grep -qE '^ +uses:.*persona-mention-reusable\.yml@persona-mention/v1-ring1' <<< "$swept"
  run grep -E 'persona-mention/(v[0-9]+-)?stable' <<< "$swept"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; stub_body_matches_template "$2" "$3" petry-projects/TalkTerm' _ "$SCRIPT" "$swept" "$t"
  [ "$status" -eq 0 ]
  # Still drift: the same stub left on the stable pin in a ring-1 repo.
  run bash -c 'source "$1"; stub_body_matches_template "$(cat "$2")" "$2" petry-projects/TalkTerm' _ "$SCRIPT" "$t"
  [ "$status" -eq 1 ]
}

@test "ring-1 repo: a correctly swept pr-review stub is compliant and its header agrees with its pin" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/pr-review.yml" swept
  swept="$(bash -c 'source "$1"; ring_repin_uses pr-review pr-review/v1-ring1 < "$2"' _ "$SCRIPT" "$t")"
  grep -qE '^ +uses:.*@pr-review/v1-ring1' <<< "$swept"
  grep -qE '^ +agent_ref: *pr-review/v1-ring1' <<< "$swept"
  run grep -E 'pr-review/(v[0-9]+-)?stable' <<< "$swept"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; stub_body_matches_template "$2" "$3" petry-projects/bmad-bgreat-suite' _ "$SCRIPT" "$swept" "$t"
  [ "$status" -eq 0 ]
}

@test "ring-1 repo: a correctly pinned stub still carrying the old stable-channel header is NOT compliant (is_already_compliant)" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/persona-mention.yml" swept old
  swept="$(bash -c 'source "$1"; ring_repin_uses persona-mention persona-mention/v1-ring1 < "$2"' _ "$SCRIPT" "$t")"
  old="$(printf '# pinned to the `persona-mention/v1-stable` channel\n%s\n' "$swept")"
  run bash -c 'source "$1"; is_already_compliant "$2" "$3" petry-projects/TalkTerm' _ "$SCRIPT" "$old" "$t"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; is_already_compliant "$2" "$3" petry-projects/TalkTerm' _ "$SCRIPT" "$swept" "$t"
  [ "$status" -eq 0 ]
}

@test "stable-pinned stub with a stable-channel header is NOT drift (tier-restricted)" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/persona-mention.yml" stable old
  stable="$(cat "$t")"
  old="$(printf '# pinned to the `persona-mention/v1-stable` channel\n%s\n' "$stable")"
  # Pass a stable-tier repo so the exemption applies
  run bash -c 'source "$1"; stub_has_stale_stable_header "$2" "$3" petry-projects/stable-repo' _ "$SCRIPT" "$old" "$t"
  [ "$status" -eq 1 ]
}

@test "strip_stale_stable_header drops only the stale comment lines and keeps per-repo edits" {
  install_gh_stub
  local body
  body="$(printf '# pinned to the `pr-auto-review/v1-stable` channel\non:\n  workflow_run:\n    workflows: ["Build"]\n')"
  run bash -c 'source "$1"; strip_stale_stable_header pr-auto-review <<< "$2"' _ "$SCRIPT" "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'workflows: ["Build"]'* ]]
  [[ "$output" != *stable* ]]
}

@test "idea stubs are deployable and present-only (never seeded)" {
  install_gh_stub
  run bash -c 'source "$1"; for w in idea-enhancer.yml idea-triage.yml initiative-planner.yml; do is_deployable_workflow "$w" && is_present_only_workflow "$w" || exit 1; done' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "sweep: ring-pinned stub with stale header is flagged as drift and header is stripped" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/persona-mention.yml" swept old
  swept="$(bash -c 'source "$1"; ring_repin_uses persona-mention persona-mention/v1-ring1 < "$2"' _ "$SCRIPT" "$t")"
  old="$(printf '# pinned to the \`persona-mention/v1-stable\` channel\n%s\n' "$swept")"
  # Verify the stub with stale header is NOT compliant
  run bash -c 'source "$1"; is_already_compliant "$2" "$3" petry-projects/TalkTerm' _ "$SCRIPT" "$old" "$t"
  [ "$status" -eq 1 ]
  # Verify that stripping the header makes it compliant
  local stripped
  stripped="$(bash -c 'source "$1"; strip_stale_stable_header persona-mention <<< "$2"' _ "$SCRIPT" "$old")"
  run bash -c 'source "$1"; is_already_compliant "$2" "$3" petry-projects/TalkTerm' _ "$SCRIPT" "$stripped" "$t"
  [ "$status" -eq 0 ]
}

@test "strip_stale_stable_header with a template replaces the whole legacy header block" {
  install_gh_stub
  local t="${REPO_ROOT}/standards/workflows/persona-mention.yml" old out
  old="$(printf '# legacy header\n#   • You MUST NOT change: the `uses:` ref — it is pinned to the\n#     `persona-mention/v1-stable` channel, a moving tag.\n#     Never repoint it.\n%s\n' "$(sed -n '/^[^#[:space:]]/,$p' "$t")")"
  out="$(bash -c 'source "$1"; strip_stale_stable_header persona-mention "$3" <<< "$2"' _ "$SCRIPT" "$old" "$t")"
  [ "$(sed -n '/^[^#[:space:]]/q;p' <<< "$out")" = "$(sed -n '/^[^#[:space:]]/q;p' "$t")" ]
  [[ "$out" != *legacy* ]]
}

@test "idea engines are engine-host targets in .github-private only" {
  install_gh_stub
  run bash -c 'source "$1"; for w in idea-enhancer.yml idea-triage.yml initiative-planner.yml; do is_engine_host_target "$w" .github-private || exit 1; ! is_engine_host_target "$w" TalkTerm || exit 2; done' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}
