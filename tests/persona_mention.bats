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
  handle: combsmith/qa-lead
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
  run pm_extract_slugs "hey @combsmith/qa-lead please look at this"
  [ "$status" -eq 0 ]
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs collapses duplicates so one mention dispatches once" {
  run pm_extract_slugs "@combsmith/qa-lead and again @combsmith/qa-lead"
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs finds several distinct personas, order preserved" {
  run pm_extract_slugs "@combsmith/qa-lead and @combsmith/dev-lead"
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
  run pm_should_route donpetry-bot OWNER "@combsmith/qa-lead please review"
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks a comment carrying the agent marker (axis 2)" {
  run pm_should_route don-petry OWNER '<!-- persona:qa-lead --> @combsmith/dev-lead over to you'
  [ "$status" -ne 0 ]
}

@test "pm_should_route blocks the combinatorial cross-persona loop" {
  # The failure mode §4.1 warns about: qa-lead answering a thread and mentioning
  # dev-lead. Marked AND bot-authored — either axis alone must stop it.
  run pm_should_route donpetry-bot OWNER '<!-- persona:qa-lead --> @combsmith/dev-lead your turn'
  [ "$status" -ne 0 ]
}

@test "pm_should_route allows a trusted human addressing a persona" {
  run pm_should_route don-petry OWNER "@combsmith/qa-lead please review"
  [ "$status" -eq 0 ]
}

@test "pm_should_route blocks an untrusted commenter" {
  run pm_should_route drive-by NONE "@combsmith/qa-lead please review"
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
  [ "$output" = "https://raw.githubusercontent.com/combsmith/.github-private/main/personas/qa-lead/persona.yml" ]
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
@combsmith/qa-lead review this
```
done'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle inside a tilde fence" {
  run pm_extract_slugs 'Example:
~~~
@combsmith/qa-lead review this
~~~
done'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle in inline code" {
  run pm_extract_slugs 'The handle is `@combsmith/qa-lead` for QA.'
  [ -z "$output" ]
}

@test "pm_extract_slugs ignores a handle in a blockquote (quote-reply)" {
  # GitHub's one-click Quote reply prefixes '>'. Re-running an agent over quoted
  # text is not what the quoter meant, and no recursion axis catches it.
  run pm_extract_slugs '> @combsmith/qa-lead please review

Agreed.'
  [ -z "$output" ]
}

@test "pm_extract_slugs still fires on a real mention beside a quote" {
  run pm_extract_slugs '> some earlier comment

@combsmith/qa-lead thoughts?'
  [ "$output" = "qa-lead" ]
}

@test "pm_extract_slugs still fires on a real mention after a code block" {
  run pm_extract_slugs 'Repro:
```
npm test
```
@combsmith/qa-lead can you look?'
  [ "$output" = "qa-lead" ]
}

@test "pm_should_route ignores a comment whose only handle is in a code fence" {
  run pm_should_route don-petry OWNER 'docs:
```
@combsmith/qa-lead
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
