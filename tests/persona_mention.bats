#!/usr/bin/env bats
# Unit tests for the persona @-mention routing core (scripts/lib/persona-mention.sh).
# Standard: standards/persona-standards.md §4.1 (addressing).
#
# The recursion guards get the most coverage here on purpose: .github-private#860
# burned 1,481 acks in 4.5h from a single self-loop, and with N mutually
# addressable personas the cycles are combinatorial rather than self-loops. A
# regression in pm_should_route is the expensive kind.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/persona-mention.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# A minimal manifest shaped like personas/qa-lead/persona.yml.
manifest() {
  local surface_block="${1:-}"
  cat <<YAML
id: qa-lead
name: QA Lead
address:
  handle: petry-projects/qa-lead
triggers:
  default_mode: advisory
  opt_out_label: qa-lead:hands-off
  surfaces:
${surface_block}
trust:
  author_association_floor: [OWNER, MEMBER, COLLABORATOR]
YAML
}

MENTION_ON='    - surface: mention
      enabled: true
      mode: advisory'

# --- slug extraction -------------------------------------------------------

@test "pm_extract_slugs finds a handle in prose" {
  run pm_extract_slugs "hey @petry-projects/qa-lead please look at this"
  [ "$status" -eq 0 ]
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs collapses duplicates so one mention dispatches once" {
  run pm_extract_slugs "@petry-projects/qa-lead and again @petry-projects/qa-lead"
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs finds several distinct personas, order preserved" {
  run pm_extract_slugs "@petry-projects/qa-lead and @petry-projects/dev-lead"
  [ "${lines[0]}" = "qa-lead" ]
  [ "${lines[1]}" = "dev-lead" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pm_extract_slugs ignores a bare user handle" {
  # '@qa-lead' is a REAL GitHub account owned by a stranger (§4.1) — the whole
  # reason handles are org-scoped. It must never route.
  run pm_extract_slugs "@qa-lead take a look"
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores another org's handle" {
  run pm_extract_slugs "@some-other-org/qa-lead take a look"
  [ -z "$output" ]
}

@test "pm_extract_slugs finds nothing in a plain comment" {
  run pm_extract_slugs "looks good to me, shipping"
  [ -z "$output" ]
}

# --- recursion guards ------------------------------------------------------

@test "pm_is_agent_comment matches any persona-authored comment, not one exact string" {
  run pm_is_agent_comment '<!-- persona:qa-lead --> risk looks low'
  [ "$status" -eq 0 ]
  run pm_is_agent_comment '<!-- persona:dev-lead ack --> on it'
  [ "$status" -eq 0 ]
}

@test "pm_is_agent_comment does not match a human comment" {
  run pm_is_agent_comment 'no marker here'
  [ "$status" -ne 0 ]
}

@test "pm_is_bot_actor recognises the agent identities" {
  run pm_is_bot_actor donpetry-bot
  [ "$status" -eq 0 ]
  run pm_is_bot_actor 'github-actions[bot]'
  [ "$status" -eq 0 ]
}

@test "pm_is_bot_actor does not match a human" {
  run pm_is_bot_actor don-petry
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks a comment authored by an agent (axis 1)" {
  run pm_should_route donpetry-bot OWNER "@petry-projects/qa-lead please review"
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks a comment carrying the agent marker (axis 2)" {
  run pm_should_route don-petry OWNER '<!-- persona:qa-lead --> @petry-projects/dev-lead over to you'
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks the combinatorial cross-persona loop" {
  # The failure mode §4.1 warns about: qa-lead answering a thread and mentioning
  # dev-lead. Marked AND bot-authored — either axis alone must stop it.
  run pm_should_route donpetry-bot OWNER '<!-- persona:qa-lead --> @petry-projects/dev-lead your turn'
  [ "$status" -ne 0 ]
}

@test "pm_should_route allows a trusted human addressing a persona" {
  run pm_should_route don-petry OWNER "@petry-projects/qa-lead please review"
  [ "$status" -eq 0 ]
}

@test "pm_should_route blocks an untrusted commenter" {
  run pm_should_route drive-by NONE "@petry-projects/qa-lead please review"
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks a comment that addresses nobody" {
  run pm_should_route don-petry OWNER "looks good to me"
  [ "$status" -ne 0 ]
}

# --- trust -----------------------------------------------------------------

@test "pm_trust_ok admits an association in the floor" {
  run pm_trust_ok MEMBER OWNER MEMBER COLLABORATOR
  [ "$status" -eq 0 ]
}

@test "pm_trust_ok denies an association outside the floor" {
  run pm_trust_ok CONTRIBUTOR OWNER MEMBER COLLABORATOR
  [ "$status" -ne 0 ]
}

@test "pm_trust_ok denies when the floor is empty" {
  # A persona that declared no floor must not be MORE permissive than one that did.
  run pm_trust_ok OWNER
  [ "$status" -ne 0 ]
}

@test "pm_trust_ok denies an empty association" {
  run pm_trust_ok "" OWNER MEMBER
  [ "$status" -ne 0 ]
}

# --- manifest decisions ----------------------------------------------------

@test "pm_mention_decision reads an explicit enabled mention surface" {
  run pm_mention_decision "$(manifest "$MENTION_ON")"
  [ "$output" = "true advisory qa-lead:hands-off" ]
}

@test "pm_mention_decision honours an explicitly disabled mention surface" {
  run pm_mention_decision "$(manifest '    - surface: mention
      enabled: false
      mode: advisory')"
  [ "$output" = "false advisory qa-lead:hands-off" ]
}

@test "pm_mention_decision falls back to default_mode advisory when unlisted" {
  run pm_mention_decision "$(manifest '    - surface: issues
      enabled: true
      mode: advisory')"
  [ "$output" = "true advisory qa-lead:hands-off" ]
}

@test "pm_mention_decision treats default_mode off as not addressable" {
  local m
  m="$(manifest '    - surface: issues
      enabled: true
      mode: advisory')"
  run pm_mention_decision "${m/default_mode: advisory/default_mode: off}"
  [ "${output% *}" = "false off" ]
}

@test "pm_mention_decision surfaces a write-mode mention" {
  run pm_mention_decision "$(manifest '    - surface: mention
      enabled: true
      mode: write
      gate_label: qa-lead')"
  [ "$output" = "true write qa-lead:hands-off" ]
}

@test "pm_mention_trust_floor defaults to the persona-wide floor" {
  run pm_mention_trust_floor "$(manifest "$MENTION_ON")"
  [ "$output" = "OWNER MEMBER COLLABORATOR" ]
}

@test "pm_mention_trust_floor lets a surface tighten the persona-wide floor" {
  run pm_mention_trust_floor "$(manifest '    - surface: mention
      enabled: true
      mode: advisory
      trust_floor: [OWNER]')"
  [ "$output" = "OWNER" ]
}

@test "pm_persona_id reads the id the manifest claims" {
  run pm_persona_id "$(manifest "$MENTION_ON")"
  [ "$output" = "qa-lead" ]
}

@test "pm_manifest_query fails loudly on unparseable YAML" {
  run pm_manifest_query '.id' <<<'this: [is: not: yaml'
  [ "$status" -ne 0 ]
}

# --- urls ------------------------------------------------------------------

@test "pm_manifest_url builds the raw manifest path by convention" {
  run pm_manifest_url qa-lead
  [ "$output" = "https://raw.githubusercontent.com/petry-projects/.github-private/main/personas/qa-lead/persona.yml" ]
}

@test "pm_manifest_url honours PERSONA_REF for testing against a branch" {
  PERSONA_REF=some-branch run pm_manifest_url qa-lead
  [[ "$output" == */some-branch/personas/qa-lead/persona.yml ]]
}

# --- mention precision (#755 finding 9) ------------------------------------
# The router must not be MORE trigger-happy than GitHub itself. Firing where
# GitHub renders no mention means pasting an example summons an agent.

@test "pm_extract_slugs ignores a handle inside a fenced code block" {
  run pm_extract_slugs 'Example:
```
@petry-projects/qa-lead review this
```
done'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle inside a tilde fence" {
  run pm_extract_slugs 'Example:
~~~
@petry-projects/qa-lead review this
~~~
done'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle in inline code" {
  run pm_extract_slugs 'The handle is `@petry-projects/qa-lead` for QA.'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle in a blockquote (quote-reply)" {
  # GitHub's one-click Quote reply prefixes '>'. Re-running an agent over quoted
  # text is not what the quoter meant, and no recursion axis catches it.
  run pm_extract_slugs '> @petry-projects/qa-lead please review

Agreed.'
  [ -z "$output" ]
}

@test "pm_extract_slugs still fires on a real mention beside a quote" {
  run pm_extract_slugs '> some earlier comment

@petry-projects/qa-lead thoughts?'
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs still fires on a real mention after a code block" {
  run pm_extract_slugs 'Repro:
```
npm test
```
@petry-projects/qa-lead can you look?'
  [ "$output" = "qa-lead" ]
}

@test "pm_should_route ignores a comment whose only handle is in a code fence" {
  run pm_should_route don-petry OWNER 'docs:
```
@petry-projects/qa-lead
```'
  [ "$status" -ne 0 ]
}

# --- gate_label (#755 finding 2) -------------------------------------------

@test "pm_mention_gate_label returns the gate for a write-mode mention" {
  run pm_mention_gate_label "$(manifest '    - surface: mention
      enabled: true
      mode: write
      gate_label: qa-lead')"
  [ "$output" = "qa-lead" ]
}

@test "pm_mention_gate_label is empty for an advisory mention" {
  run pm_mention_gate_label "$(manifest "$MENTION_ON")"
  [ -z "$output" ]
}

@test "pm_mention_gate_label is empty when the surface is absent" {
  run pm_mention_gate_label "$(manifest '    - surface: issues
      enabled: true
      mode: advisory')"
  [ -z "$output" ]
}

@test "gate_label survives an empty opt_out_label (the read-shift trap)" {
  # A 4th space-separated field on pm_mention_decision would silently shift an
  # empty opt_out_label's place onto the gate. Separate functions cannot.
  local m
  m="$(manifest '    - surface: mention
      enabled: true
      mode: write
      gate_label: qa-lead')"
  m="${m/  opt_out_label: qa-lead:hands-off/  opt_out_label: \"\"}"
  run pm_mention_gate_label "$m"
  [ "$output" = "qa-lead" ]
}

# --- stop markers (#1133) --------------------------------------------------
# A human hold (needs-human-review, dev-lead:needs-human, <id>:hands-off) must
# stop a MENTIONED persona the way it stops the event-driven surfaces. Each
# persona declares its brakes in personas/<id>/interaction.yml; the router reads
# them from there — no marker is ever a literal in the routing logic (AC #2).

# A minimal interaction contract shaped like personas/qa-lead/interaction.yml.
interaction() {
  local markers="${1:-  stop_markers:
    - qa-lead:hands-off
    - needs-human-review
    - dev-lead:needs-human}"
  cat <<YAML
schema_version: 1
role: qa-lead
kind: persona
interaction:
${markers}
YAML
}

@test "pm_interaction_url builds the raw contract path by convention" {
  run pm_interaction_url qa-lead
  [ "$output" = "https://raw.githubusercontent.com/petry-projects/.github-private/main/personas/qa-lead/interaction.yml" ]
}

@test "pm_interaction_url honours PERSONA_REF for testing against a branch" {
  PERSONA_REF=some-branch run pm_interaction_url qa-lead
  [[ "$output" == */some-branch/personas/qa-lead/interaction.yml ]]
}

@test "pm_stop_markers reads every declared marker from the contract" {
  run pm_stop_markers "$(interaction)"
  [ "${lines[0]}" = "qa-lead:hands-off" ]
  [ "${lines[1]}" = "needs-human-review" ]
  [ "${lines[2]}" = "dev-lead:needs-human" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "pm_stop_markers is empty when the contract declares none" {
  run pm_stop_markers "$(interaction '  stop_markers: []')"
  [ -z "$output" ]
}

@test "pm_stop_markers is empty when stop_markers is absent entirely" {
  run pm_stop_markers "$(interaction '  budget: pr-automation-budget')"
  [ -z "$output" ]
}

@test "pm_stop_markers rejects a boolean stop_markers (false is not 'absent')" {
  # `false` must not be quietly rewritten into "no markers" by a `//` fallback —
  # a malformed contract fails closed so the router never routes onto a held item.
  run pm_stop_markers "$(interaction '  stop_markers: false')"
  [ "$status" -ne 0 ]
}

@test "pm_stop_markers rejects an object stop_markers" {
  run pm_stop_markers "$(interaction '  stop_markers:
    needs-human-review: true')"
  [ "$status" -ne 0 ]
}

@test "pm_stop_markers rejects an empty-string marker entry" {
  run pm_stop_markers "$(interaction '  stop_markers:
    - ""
    - needs-human-review')"
  [ "$status" -ne 0 ]
}

@test "pm_stop_markers rejects a non-string marker entry" {
  run pm_stop_markers "$(interaction '  stop_markers:
    - 42
    - needs-human-review')"
  [ "$status" -ne 0 ]
}

@test "pm_first_stop_marker fails closed on a boolean stop_markers (never 'no markers')" {
  # An item carrying a hold label must NOT be read as routable just because the
  # contract's stop_markers is a malformed `false`.
  run pm_first_stop_marker "$(interaction '  stop_markers: false')" <<<'needs-human-review'
  [ "$status" -eq 2 ]
}

@test "pm_first_stop_marker names the marker holding the item (present -> skip)" {
  # Item carries the escalation brake -> the router must skip and log the marker.
  run pm_first_stop_marker "$(interaction)" <<<'needs-human-review
some-other-label'
  [ "$output" = "needs-human-review" ]
}

@test "pm_first_stop_marker fires on dev-lead:needs-human (cross-persona hold)" {
  run pm_first_stop_marker "$(interaction)" <<<'dev-lead:needs-human'
  [ "$output" = "dev-lead:needs-human" ]
}

@test "pm_first_stop_marker honours the persona's own opt-out among its markers" {
  run pm_first_stop_marker "$(interaction)" <<<'qa-lead:hands-off'
  [ "$output" = "qa-lead:hands-off" ]
}

@test "pm_first_stop_marker returns the FIRST declared marker present, in order" {
  # Two markers present; the contract's declaration order decides which is logged.
  run pm_first_stop_marker "$(interaction)" <<<'dev-lead:needs-human
needs-human-review'
  [ "$output" = "needs-human-review" ]
}

@test "pm_first_stop_marker is empty when no marker is present (absent -> route)" {
  run pm_first_stop_marker "$(interaction)" <<<'enhancement
good-first-issue'
  [ -z "$output" ]
  [ "$status" -eq 0 ]
}

@test "pm_first_stop_marker is empty on an empty label set" {
  run pm_first_stop_marker "$(interaction)" <<<''
  [ -z "$output" ]
}

@test "pm_first_stop_marker matches a marker whole-line, never as a substring" {
  # 'needs-human-review' must not fire on a label that merely contains it.
  run pm_first_stop_marker "$(interaction)" <<<'needs-human-review-later'
  [ -z "$output" ]
}

@test "pm_first_stop_marker routes when the contract declares no markers" {
  run pm_first_stop_marker "$(interaction '  stop_markers: []')" <<<'needs-human-review'
  [ -z "$output" ]
}

@test "pm_first_stop_marker fails closed on an unparseable contract (never 'no markers')" {
  # A 200 with a corrupt body must not be read as "not held" — it must fail the
  # job, exactly as a 5xx does. pm_stop_markers exits non-zero on bad YAML and
  # that propagates rather than being swallowed into an empty marker set.
  run pm_first_stop_marker 'this: [is: not: yaml' <<<'needs-human-review'
  [ "$status" -eq 2 ]
}

# --- interaction fetch disposition (AC #3) ---------------------------------
# The fetch mirrors the manifest fetch EXACTLY: a 200 is the contract, a 404 is
# a real answer ("no contract — refuse this slug"), and anything else is a
# FAILURE to get an answer and must fail the job. Never read a fetch failure as
# "no stop markers" — that is fail-open in the direction that matters.

@test "pm_fetch_disposition treats 200 as the contract to read" {
  run pm_fetch_disposition 200
  [ "$output" = "read" ]
}

@test "pm_fetch_disposition treats 404 as absent (refuse this slug)" {
  run pm_fetch_disposition 404
  [ "$output" = "absent" ]
}

@test "pm_fetch_disposition fails closed on a 5xx" {
  run pm_fetch_disposition 500
  [ "$output" = "fail" ]
  run pm_fetch_disposition 503
  [ "$output" = "fail" ]
}

@test "pm_fetch_disposition fails closed on a curl transport error (000)" {
  run pm_fetch_disposition 000
  [ "$output" = "fail" ]
}

@test "pm_fetch_disposition fails closed on any other status" {
  run pm_fetch_disposition 403
  [ "$output" = "fail" ]
}

# --- pm_should_retry_status (bounded-retry decision) -----------------------
# Only a transient status is worth retrying; a definitive answer must not be.

@test "pm_should_retry_status retries a curl transport error (000)" {
  run pm_should_retry_status 000
  [ "$status" -eq 0 ]
}

@test "pm_should_retry_status retries a 5xx" {
  run pm_should_retry_status 500
  [ "$status" -eq 0 ]
  run pm_should_retry_status 503
  [ "$status" -eq 0 ]
}

@test "pm_should_retry_status does NOT retry a definitive 200 or 404" {
  run pm_should_retry_status 200
  [ "$status" -eq 1 ]
  run pm_should_retry_status 404
  [ "$status" -eq 1 ]
}

@test "pm_should_retry_status does NOT retry an other 4xx" {
  run pm_should_retry_status 403
  [ "$status" -eq 1 ]
}

# ===========================================================================
# The pull_request surface (#1165) — the router also serves PR events.
# ===========================================================================
# Which personas fire on pull_request is DERIVED from each manifest's declared
# surfaces (#756), and every brake the mention path binds — stop markers,
# opt-out, write-mode gate, trust floor, the bot/marker recursion guards — binds
# here too (AC #2/#4). These are pure-function tests so the new path is proven
# per branch, not by inspection.

PR_ON='    - surface: pull_request
      enabled: true
      mode: advisory'

# --- pm_surface_decision (derive-don't-enumerate) --------------------------
# Unlike pm_mention_decision, an EXPLICIT surface row is required: there is no
# default_mode fallback, so a persona fires on pull_request only when it declares
# that surface enabled.

@test "pm_surface_decision reads an explicit enabled pull_request surface" {
  run pm_surface_decision "$(manifest "$PR_ON")" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "true advisory qa-lead:hands-off" ]
}

@test "pm_surface_decision reports a persona that does NOT declare the surface as off (not dispatched)" {
  # The mention manifest declares no pull_request row — it must not fire on a PR.
  run pm_surface_decision "$(manifest "$MENTION_ON")" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "false off qa-lead:hands-off" ]
}

@test "pm_surface_decision does NOT fall back to default_mode for an unlisted surface" {
  # A persona whose default_mode is advisory but which lists only 'issues' must
  # still be OFF for pull_request — derive from declared surfaces, never enumerate.
  run pm_surface_decision "$(manifest '    - surface: issues
      enabled: true
      mode: advisory')" pull_request
  [ "$status" -eq 0 ]
  [ "${output% *}" = "false off" ]
}

@test "pm_surface_decision honours an explicitly disabled pull_request surface" {
  run pm_surface_decision "$(manifest '    - surface: pull_request
      enabled: false
      mode: advisory')" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "false advisory qa-lead:hands-off" ]
}

@test "pm_surface_decision surfaces a write-mode pull_request surface" {
  run pm_surface_decision "$(manifest '    - surface: pull_request
      enabled: true
      mode: write
      gate_label: qa-lead')" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "true write qa-lead:hands-off" ]
}

# --- pm_surface_trust_floor / pm_surface_gate_label ------------------------

@test "pm_surface_trust_floor defaults to the persona-wide floor for pull_request" {
  run pm_surface_trust_floor "$(manifest "$PR_ON")" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "OWNER MEMBER COLLABORATOR" ]
}

@test "pm_surface_trust_floor lets a pull_request surface tighten the persona-wide floor" {
  run pm_surface_trust_floor "$(manifest '    - surface: pull_request
      enabled: true
      mode: advisory
      trust_floor: [OWNER]')" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "OWNER" ]
}

@test "pm_surface_trust_floor cannot widen the persona-wide floor" {
  # The security property: a surface floor can only tighten, never loosen. The
  # persona-wide floor permits [OWNER, MEMBER, COLLABORATOR]; the surface floor
  # adds CONTRIBUTOR, which is NOT in the global floor and must be dropped by the
  # intersection. If a later change swapped intersect for surface-wins,
  # CONTRIBUTOR would get through and this test would fail.
  run pm_surface_trust_floor "$(manifest '    - surface: pull_request
      enabled: true
      mode: advisory
      trust_floor: [OWNER, CONTRIBUTOR]')" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "OWNER" ]
}

@test "pm_surface_gate_label returns the gate for a write-mode pull_request surface" {
  run pm_surface_gate_label "$(manifest '    - surface: pull_request
      enabled: true
      mode: write
      gate_label: qa-lead')" pull_request
  [ "$status" -eq 0 ]
  [ "$output" = "qa-lead" ]
}

@test "pm_surface_gate_label is empty for an advisory pull_request surface" {
  run pm_surface_gate_label "$(manifest "$PR_ON")" pull_request
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- pm_surface_declares_event (gate on declared events, not just enabled) --
# A pull_request surface fires only on the actions it declares in `events`. A row
# with no events list is undeclared for every action, so `synchronize` never
# fires against a persona that only lists opened/ready_for_review (maintainer
# review item 1).

PR_EVENTS='    - surface: pull_request
      enabled: true
      mode: advisory
      events: [opened, ready_for_review]'

@test "pm_surface_declares_event is true for a declared action (opened)" {
  run pm_surface_declares_event "$(manifest "$PR_EVENTS")" pull_request opened
  [ "$status" -eq 0 ]
}

@test "pm_surface_declares_event is true for a declared action (ready_for_review)" {
  run pm_surface_declares_event "$(manifest "$PR_EVENTS")" pull_request ready_for_review
  [ "$status" -eq 0 ]
}

@test "pm_surface_declares_event is false for an undeclared action (synchronize)" {
  run pm_surface_declares_event "$(manifest "$PR_EVENTS")" pull_request synchronize
  [ "$status" -ne 0 ]
}

@test "pm_surface_declares_event is false for a row that declares no events" {
  # PR_ON declares the surface enabled but lists no events — undeclared for every
  # action, so it does not fire even on opened.
  run pm_surface_declares_event "$(manifest "$PR_ON")" pull_request opened
  [ "$status" -ne 0 ]
}

# --- pm_persona_runtime_reusable (own-runtime personas are not router-served) --

@test "pm_persona_runtime_reusable prints the path for a dev-lead-shaped manifest" {
  m="$(manifest "$PR_ON")
runtime:
  reusable: .github/workflows/dev-lead-reusable.yml"
  run pm_persona_runtime_reusable "$m"
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/dev-lead-reusable.yml" ]
}

@test "pm_persona_runtime_reusable prints nothing for runtime.identity only" {
  m="$(manifest "$PR_ON")
runtime:
  identity: qa-lead"
  run pm_persona_runtime_reusable "$m"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pm_persona_runtime_reusable prints nothing when there is no runtime block" {
  run pm_persona_runtime_reusable "$(manifest "$PR_ON")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pm_persona_runtime_reusable fails closed on an unparseable manifest" {
  run pm_persona_runtime_reusable "id: [unclosed"
  [ "$status" -ne 0 ]
}

# --- pm_pr_should_route (event pre-filter) ---------------------------------
# Same two recursion axes and trust floor as pm_should_route, but WITHOUT the
# @-mention requirement: a PR is derived, not addressed. A PR event must not
# become an ungated write surface, so the guards apply on this path too (AC #4).

@test "pm_pr_should_route allows a trusted human's PR with no @-mention in the body" {
  run pm_pr_should_route don-petry don-petry OWNER "Ordinary PR description, no handles."
  [ "$status" -eq 0 ]
}

@test "pm_pr_should_route blocks a PR opened by an agent identity (axis 1a: author)" {
  run pm_pr_should_route donpetry-bot donpetry-bot OWNER "PR body"
  [ "$status" -eq 1 ]
}

@test "pm_pr_should_route blocks a bot push/reopen on a human-authored PR (axis 1b: actor)" {
  # PR author is a human, but the triggering actor is an agent identity — the
  # codeant/tier-3 recursion finding: an agent update must not re-arm the router.
  run pm_pr_should_route don-petry github-actions[bot] OWNER "PR body"
  [ "$status" -eq 1 ]
}

@test "pm_pr_should_route blocks a PR whose body carries the agent marker (axis 2)" {
  run pm_pr_should_route don-petry don-petry OWNER '<!-- persona:qa-lead --> automated PR'
  [ "$status" -eq 1 ]
}

@test "pm_pr_should_route blocks a PR from an author below the default floor" {
  run pm_pr_should_route drive-by drive-by CONTRIBUTOR "PR body"
  [ "$status" -eq 1 ]
}

# --- pm_pr_route_verdict (the composed PR gauntlet — AC #2/#4 proof) --------
# Given a manifest that DECLARES the pull_request surface enabled and its
# interaction contract, decide the verdict for one PR: stop-marker → write-gate
# → trust-floor → dispatch. Stop markers bind here exactly as on the mention
# path, and an unreadable contract fails CLOSED — proven per branch below.

@test "pm_pr_route_verdict dispatches when no stop marker holds the PR" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" "$(interaction)" OWNER <<<'enhancement'
  [ "$status" -eq 0 ]
  [ "$output" = "dispatch advisory" ]
}

@test "pm_pr_route_verdict skips and NAMES the marker when the PR is held" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" "$(interaction)" OWNER <<<'needs-human-review'
  [ "$status" -eq 0 ]
  [ "$output" = "skip stop-marker needs-human-review" ]
}

@test "pm_pr_route_verdict honours a cross-persona hold on the PR path" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" "$(interaction)" OWNER <<<'dev-lead:needs-human'
  [ "$status" -eq 0 ]
  [ "$output" = "skip stop-marker dev-lead:needs-human" ]
}

@test "pm_pr_route_verdict fails CLOSED on an unparseable contract (never dispatches a held PR)" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" 'this: [is: not: yaml' OWNER <<<'enhancement'
  [ "$status" -eq 2 ]
}

@test "pm_pr_route_verdict fails CLOSED on a malformed boolean stop_markers" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" "$(interaction '  stop_markers: false')" OWNER <<<'enhancement'
  [ "$status" -eq 2 ]
}

@test "pm_pr_route_verdict dispatches when the contract declares no markers" {
  run pm_pr_route_verdict "$(manifest "$PR_ON")" "$(interaction '  stop_markers: []')" OWNER <<<'needs-human-review'
  [ "$status" -eq 0 ]
  [ "$output" = "dispatch advisory" ]
}

@test "pm_pr_route_verdict skips an unarmed write-mode PR (no gate label present)" {
  run pm_pr_route_verdict "$(manifest '    - surface: pull_request
      enabled: true
      mode: write
      gate_label: qa-lead')" "$(interaction)" OWNER <<<'enhancement'
  [ "$status" -eq 0 ]
  [ "$output" = "skip not-armed qa-lead" ]
}

@test "pm_pr_route_verdict dispatches an armed write-mode PR" {
  run pm_pr_route_verdict "$(manifest '    - surface: pull_request
      enabled: true
      mode: write
      gate_label: qa-lead')" "$(interaction)" OWNER <<<'qa-lead'
  [ "$status" -eq 0 ]
  [ "$output" = "dispatch write" ]
}

@test "pm_pr_route_verdict fails CLOSED on a write surface with no gate_label (never an ungated write)" {
  run pm_pr_route_verdict "$(manifest '    - surface: pull_request
      enabled: true
      mode: write')" "$(interaction)" OWNER <<<'enhancement'
  [ "$status" -eq 3 ]
}

@test "pm_pr_route_verdict skips a PR author below the persona floor" {
  run pm_pr_route_verdict "$(manifest '    - surface: pull_request
      enabled: true
      mode: advisory
      trust_floor: [OWNER]')" "$(interaction)" MEMBER <<<'enhancement'
  [ "$status" -eq 0 ]
  [ "$output" = "skip below-floor" ]
}
