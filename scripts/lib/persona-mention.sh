# shellcheck shell=bash
# scripts/lib/persona-mention.sh — Persona @-mention routing core
#
# Reusable Bash library implementing the routing decisions behind §4.1 of
#
#   standards/persona-standards.md
#
# A persona is addressed by an org TEAM handle — `@combsmith/<role>` — and
# the manifest at `personas/<role>/persona.yml` in combsmith/.github-private
# is the index-of-record for whether that mention should do anything. There is no
# derived index: `validate-personas.py` enforces `address.handle`'s slug == `id`
# == the persona's directory name, so a handle resolves to a manifest path by
# convention. A 404 simply means "not a persona" — which is also how a real,
# non-persona team (`@combsmith/org-leads`) falls through harmlessly.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# This library is `set -euo pipefail`-safe and designed to be sourced by a parent
# script (`# shellcheck source=scripts/lib/persona-mention.sh`). It does NOT call
# `set` itself and runs nothing at source time.
#
# Reads (all optional, with defaults):
#   - $PERSONA_ORG        — org that owns the persona teams (default: combsmith)
#   - $PERSONA_REPO       — repo holding personas/<id>/persona.yml
#                           (default: combsmith/.github-private)
#   - $PERSONA_REF        — ref to read manifests at (default: main)
#   - $PERSONA_BOT_LOGINS — space/comma-separated logins whose comments never
#                           trigger a persona (default: donpetry-bot github-actions[bot])
#
# ----------------------------------------------------------------------------
# Recursion is the hazard this library exists to bound
# ----------------------------------------------------------------------------
# Comments posted with a PAT re-trigger workflows (unlike GITHUB_TOKEN).
# .github-private#860 burned 1,481 identical acks in 4.5h from a SINGLE
# self-loop, and #538 traced it to an agent emitting a literal '@<handle>' in
# its own comment. With N mutually addressable personas the cycles stop being
# self-loops and become combinatorial: qa-lead answering a thread that mentions
# dev-lead is enough.
#
# So every routing decision here excludes on TWO independent axes, per §4.1:
#   1. the bot actor  — a comment authored by an agent identity never routes, and
#   2. the marker     — a comment carrying '<!-- persona:' never routes,
# and callers MUST NOT emit a literal '@<org>/<slug>' in any agent-authored
# comment. Belt and suspenders: either axis alone closes the common loop, and
# both together close the case where an agent posts under a human's PAT.

PERSONA_AGENT_MARKER='<!-- persona:'

# pm_bot_logins — emit the configured agent logins, one per line.
# Accepts comma- and/or whitespace-separated values.
pm_bot_logins() {
  local raw="${PERSONA_BOT_LOGINS:-donpetry-bot github-actions[bot]}" item
  for item in ${raw//,/ }; do
    [ -n "$item" ] && printf '%s\n' "$item"
  done
}

# pm_is_bot_actor <login> — 0 if this login is an agent identity.
pm_is_bot_actor() {
  local login="$1" bot
  [ -n "$login" ] || return 1
  while IFS= read -r bot; do
    [ "$login" = "$bot" ] && return 0
  done < <(pm_bot_logins)
  return 1
}

# pm_is_agent_comment <body> — 0 if this body carries the agent marker.
# Axis 2 of the recursion guard. Deliberately matches the marker PREFIX, not a
# specific agent's full marker: #860's first fix matched one exact ack string and
# still self-looped through a different agent-authored comment, so any comment a
# persona writes about its own work is excluded, not just its ack.
pm_is_agent_comment() {
  case "$1" in
    *"$PERSONA_AGENT_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# pm_extract_slugs <body> — emit each DISTINCT persona slug addressed in body.
#
# Matches '@<org>/<slug>' where slug is kebab-case, mirroring the schema's
# address.handle pattern. Order is preserved (first mention wins) and duplicates
# collapse, so '@combsmith/qa-lead ... @combsmith/qa-lead' dispatches
# once rather than twice.
#
# A match here is NOT a decision to run: the slug still has to resolve to a
# manifest that enables the mention surface. Real teams (org-leads) match the
# shape and are dropped later by a 404.
# pm_strip_unaddressable <body> — drop regions where a handle must not count.
#
# Three regions, two reasons:
#
#   fenced code (``` / ~~~)  — GitHub renders NO mention here and notifies nobody.
#   inline code (`...`)      — likewise. Firing on these means the router is more
#                              trigger-happy than GitHub's own semantics: pasting
#                              a usage example, or documenting the handle, would
#                              summon the persona.
#   blockquotes (^>)         — a DELIBERATE divergence. GitHub *does* render and
#                              notify on a quoted mention, but GitHub's one-click
#                              "Quote reply" copies a whole prior comment prefixed
#                              with '>', and re-running an agent over quoted text
#                              is almost never what the quoter meant. Neither
#                              recursion axis catches it (a human quoting a human
#                              is not a bot and carries no marker). To address a
#                              persona, mention it outside the quote.
pm_strip_unaddressable() {
  printf '%s' "$1" | awk '
    # Toggle on fence open/close; never emit the fence or its contents.
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    infence                  { next }
    /^[[:space:]]*>/         { next }          # blockquote line
    { gsub(/`[^`]*`/, " "); print }            # inline code -> whitespace
  '
}

# pm_extract_slugs <body> — emit each DISTINCT persona slug addressed in body.
pm_extract_slugs() {
  local body="$1" org="${PERSONA_ORG:-combsmith}"
  pm_strip_unaddressable "$body" \
    | grep -oE "@${org}/[a-z0-9]+(-[a-z0-9]+)*" \
    | sed "s|@${org}/||" \
    | awk '!seen[$0]++'
}

# pm_manifest_url <slug> — the raw URL of that persona's manifest.
pm_manifest_url() {
  local repo="${PERSONA_REPO:-combsmith/.github-private}"
  local ref="${PERSONA_REF:-main}"
  printf 'https://raw.githubusercontent.com/%s/%s/personas/%s/persona.yml\n' \
    "$repo" "$ref" "$1"
}

# pm_trust_ok <author_association> <floor...> — 0 if the association clears the
# floor. The floor is a set, not a ladder: GitHub's author_association has no
# total order we should invent (CONTRIBUTOR vs COLLABORATOR is not a rank), so
# membership is the only honest test. An empty floor denies — a persona that
# forgot to declare trust must not be more permissive than one that did.
pm_trust_ok() {
  local assoc="$1" allowed
  shift
  [ -n "$assoc" ] || return 1
  for allowed in "$@"; do
    [ "$assoc" = "$allowed" ] && return 0
  done
  return 1
}

# pm_should_route <actor> <author_association> <body> — 0 if this comment is
# worth spending an API call on.
#
# The CHEAP pre-filter, evaluated before any manifest fetch and (in the workflow)
# before secrets are exposed to the job. It applies the conservative default
# floor from §4 — [OWNER, MEMBER, COLLABORATOR]. A persona may TIGHTEN that in
# its own manifest but never loosen it, so gating here can only ever be stricter
# than the union of what the personas allow, never laxer.
pm_should_route() {
  local actor="$1" assoc="$2" body="$3"

  pm_is_bot_actor "$actor" && return 1        # axis 1: bot actor
  pm_is_agent_comment "$body" && return 1     # axis 2: agent marker
  pm_trust_ok "$assoc" OWNER MEMBER COLLABORATOR || return 1
  [ -n "$(pm_extract_slugs "$body")" ] || return 1
  return 0
}

# ----------------------------------------------------------------------------
# Manifest decisions
# ----------------------------------------------------------------------------
# The manifest is the index-of-record (§1.1): the router asks it, and restates
# nothing. These take manifest YAML on stdin so they stay pure and testable —
# fetching is the caller's job.

# pm_manifest_query <jq-filter> — run a jq filter over a YAML manifest on stdin.
# Uses python+yaml rather than yq: the fleet's runners are guaranteed python3 +
# PyYAML (validate-personas.py depends on both) but not yq.
pm_manifest_query() {
  local filter="$1" json
  # Capture rather than pipe straight into jq: a pipeline reports the LAST
  # command's status, so `python3 ... | jq` would swallow a parse failure and jq
  # would happily read empty stdin, exit 0, and emit nothing. The caller cannot
  # then distinguish "manifest says no" from "manifest never parsed" — a silent
  # mis-route. The library is sourced by `set -euo pipefail` parents but must not
  # call `set` itself (caller contract), so pipefail is not ours to switch on.
  json="$(python3 -c '
import json, sys, yaml
try:
    print(json.dumps(yaml.safe_load(sys.stdin.read())))
except Exception as exc:
    sys.stderr.write("persona-mention: unparseable manifest: %s\n" % exc)
    sys.exit(2)
')" || return 2
  printf '%s' "$json" | jq -r "$filter"
}

# pm_mention_decision <manifest-yaml> — emit "<enabled> <mode> <opt_out_label>".
#
# Resolves the `mention` surface against the trigger matrix: an explicit row wins;
# otherwise triggers.default_mode applies (§4). default_mode 'off' means the
# persona is not addressable at all.
pm_mention_decision() {
  # shellcheck disable=SC2016  # $t/$s/$m are jq variables, not shell expansions
  printf '%s' "$1" | pm_manifest_query '
    (.triggers // {}) as $t
    | ($t.surfaces // []) as $s
    | ($s | map(select(.surface == "mention")) | first) as $m
    | (if $m == null
       then (if ($t.default_mode // "off") == "advisory" then "true advisory" else "false off" end)
       else ((($m.enabled // false) | tostring) + " " + ($m.mode // "advisory"))
       end) as $decision
    | $decision + " " + ($t.opt_out_label // "")
  '
}

# pm_mention_trust_floor <manifest-yaml> — emit the floor for the mention
# surface, space-separated. A per-surface trust_floor tightens the persona-wide
# trust.author_association_floor; when absent, the persona-wide floor applies
# (§5). Emits nothing when neither is declared — pm_trust_ok then denies, which
# is the safe direction.
pm_mention_trust_floor() {
  # shellcheck disable=SC2016  # $m is a jq variable, not a shell expansion
  printf '%s' "$1" | pm_manifest_query '
    ((.triggers.surfaces // []) | map(select(.surface == "mention")) | first) as $m
    | ($m.trust_floor // .trust.author_association_floor // [])
    | join(" ")
  '
}

# pm_mention_gate_label <manifest-yaml> — the label that ARMS a write-mode
# mention, or empty.
#
# Its own function rather than a fourth field on pm_mention_decision: that
# returns space-separated values, and an EMPTY optional field silently shifts the
# next one into its place ("true write  qa-lead" would parse gate_label as the
# opt_out_label). A security gate is the last place to accept that.
#
# §4 rule 2 makes gate_label schema-REQUIRED when mode == write. The schema
# enforces that it is DECLARED; the caller must enforce that it is APPLIED —
# declaring a lock is not locking the door.
pm_mention_gate_label() {
  # shellcheck disable=SC2016  # $m is a jq variable, not a shell expansion
  printf '%s' "$1" | pm_manifest_query '
    ((.triggers.surfaces // []) | map(select(.surface == "mention")) | first) as $m
    | ($m.gate_label // "")
  '
}

# pm_persona_id <manifest-yaml> — the persona id, for cross-checking the slug we
# routed on against what the manifest actually claims to be. They cannot diverge
# while validate-personas.py holds, so a mismatch means the invariant broke and
# the caller should refuse rather than guess.
pm_persona_id() {
  printf '%s' "$1" | pm_manifest_query '.id // ""'
}
