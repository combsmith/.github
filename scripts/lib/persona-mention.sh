# shellcheck shell=bash
# scripts/lib/persona-mention.sh — Persona @-mention routing core
#
# Reusable Bash library implementing the routing decisions behind §4.1 of
#
#   standards/persona-standards.md
#
# A persona is addressed by an org TEAM handle — `@petry-projects/<role>` — and
# the manifest at `personas/<role>/persona.yml` in petry-projects/.github-private
# is the index-of-record for whether that mention should do anything. There is no
# derived index: `validate-personas.py` enforces `address.handle`'s slug == `id`
# == the persona's directory name, so a handle resolves to a manifest path by
# convention. A 404 simply means "not a persona" — which is also how a real,
# non-persona team (`@petry-projects/org-leads`) falls through harmlessly.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# This library is `set -euo pipefail`-safe and designed to be sourced by a parent
# script (`# shellcheck source=scripts/lib/persona-mention.sh`). It does NOT call
# `set` itself and runs nothing at source time.
#
# Reads (all optional, with defaults):
#   - $PERSONA_ORG        — org that owns the persona teams (default: petry-projects)
#   - $PERSONA_REPO       — repo holding personas/<id>/persona.yml
#                           (default: petry-projects/.github-private)
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
# collapse, so '@petry-projects/qa-lead ... @petry-projects/qa-lead' dispatches
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
  local body="$1" org="${PERSONA_ORG:-petry-projects}"
  pm_strip_unaddressable "$body" \
    | grep -oE "@${org}/[a-z0-9]+(-[a-z0-9]+)*" \
    | sed "s|@${org}/||" \
    | awk '!seen[$0]++'
}

# pm_manifest_url <slug> — the raw URL of that persona's manifest.
pm_manifest_url() {
  local repo="${PERSONA_REPO:-petry-projects/.github-private}"
  local ref="${PERSONA_REF:-main}"
  printf 'https://raw.githubusercontent.com/%s/%s/personas/%s/persona.yml\n' \
    "$repo" "$ref" "$1"
}

# pm_interaction_url <slug> — the raw URL of that persona's interaction contract
# (personas/<slug>/interaction.yml). Built by the SAME convention and by the same
# unauthenticated raw.githubusercontent pattern as pm_manifest_url — the repo is
# PUBLIC, so no token is used and none should be (see the fetch note in the
# router). The contract is where each persona declares its stop_markers, so the
# router derives the human-hold brakes from it rather than restating them (#1133).
pm_interaction_url() {
  local repo="${PERSONA_REPO:-petry-projects/.github-private}"
  local ref="${PERSONA_REF:-main}"
  printf 'https://raw.githubusercontent.com/%s/%s/personas/%s/interaction.yml\n' \
    "$repo" "$ref" "$1"
}

# pm_fetch_disposition <http_code> — classify a raw.githubusercontent fetch into
# what the caller should DO, mirroring the manifest fetch's status handling
# exactly (#1133 AC #3):
#
#   200        -> "read"    the body is the answer
#   404        -> "absent"  a real ANSWER — the resource is not there
#   any other  -> "fail"    a FAILURE to get an answer (5xx, a 000 curl transport
#                           error, an unexpected 4xx) — never read as "absent"
#
# For the interaction contract this is fail-closed in the direction that matters:
# a transient 5xx must NEVER be mistaken for "this persona declares no stop
# markers" and let a mention through on a held item. Pure and side-effect-free so
# the disposition is unit-tested (tests/persona_mention.bats) rather than only
# exercisable by triggering the workflow.
pm_fetch_disposition() {
  case "$1" in
    200) printf 'read\n' ;;
    404) printf 'absent\n' ;;
    *)   printf 'fail\n' ;;
  esac
}

# pm_should_retry_status <http_code> — 0 when a fetch that returned this status is
# worth RETRYING, 1 when the status is a definitive answer that must not be
# retried. The bounded-retry decision, kept pure here so the backoff loop in the
# workflow is thin and the classification is unit-tested:
#
#   000        -> retry   a curl transport error (DNS, connect, timeout)
#   5xx        -> retry   a transient server-side failure
#   any other  -> stop    200 (the body), 404 ("not a persona"), or any other 4xx
#                         is a DEFINITIVE answer — retrying it only wastes time
#
# This never changes the fail-loud contract: after the caller exhausts its bounded
# attempts it still hands the final status to pm_fetch_disposition (or the router's
# own case), so a persistently transient failure aborts the route rather than being
# mistaken for "not a persona" / "no stop markers".
pm_should_retry_status() {
  case "$1" in
    000|5[0-9][0-9]) return 0 ;;
    *)               return 1 ;;
  esac
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

# pm_manifest_query <jq-filter> [jq-args...] — run a jq filter over a YAML
# manifest on stdin. Uses python+yaml rather than yq: the fleet's runners are
# guaranteed python3 + PyYAML (validate-personas.py depends on both) but not yq.
#
# Extra arguments after the filter are forwarded to jq verbatim, so a caller can
# pass `--arg surface pull_request` and select a surface by variable rather than
# baking it into the filter string. Callers that pass only a filter are
# unaffected — `"$@"` is empty and jq sees just the filter.
pm_manifest_query() {
  local filter="$1" json
  shift
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
  printf '%s' "$json" | jq -r "$@" "$filter"
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
# (§5). Surface floor, if declared, overrides the persona-wide floor. Emits
# nothing when neither is declared — pm_trust_ok then denies, which is the safe
# direction.
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

# ----------------------------------------------------------------------------
# Stop markers — the human hold, honoured on the mention surface (#1133)
# ----------------------------------------------------------------------------
# A persona declares its brakes in personas/<id>/interaction.yml as
# `interaction.stop_markers` — e.g. needs-human-review, dev-lead:needs-human,
# <id>:hands-off. The event-driven surfaces already honour all of them (the
# .github-private pull_request advisory gate; hold-gate.sh). The mention router
# honoured only the opt-out label, so a mention on a HELD item still dispatched
# the persona — fail-open in the direction that matters. These functions let the
# router honour the persona's OWN declared markers, read from the contract, so no
# marker is ever a literal in the routing logic (#1133 AC #2).

# pm_stop_markers <interaction-yaml> — emit each declared stop marker, one per
# line (empty when none is declared or the block is absent). Reads the contract
# on stdin so it stays pure and testable — fetching is the caller's job, exactly
# like the manifest decisions above.
#
# A DECLARED stop_markers value must be an array of non-empty strings; anything
# else — an object, a boolean (`false`), an empty string, or a non-string entry
# — is a malformed contract and returns non-zero so pm_first_stop_marker fails
# CLOSED rather than reading the item as "not held" (#1134). The value is
# selected with `has` before any fallback so `//` can never quietly rewrite a
# declared `false`/`null` into "absent" — only a genuinely missing key (and an
# explicit `null`) is treated as "no markers declared".
pm_stop_markers() {
  # shellcheck disable=SC2016  # jq filter, not a shell expansion
  printf '%s' "$1" | pm_manifest_query '
    ((.interaction // {}) as $i
     | if (($i | type) == "object") and ($i | has("stop_markers")) then $i.stop_markers
       elif ((type == "object") and has("stop_markers")) then .stop_markers
       else [] end) as $m
    | if $m == null then empty
      elif ($m | type) != "array" then
        error("persona-mention: stop_markers must be an array of non-empty strings, got \($m | type)")
      else
        $m[] | if (type != "string") or (. == "") then
          error("persona-mention: stop_markers entries must be non-empty strings")
        else . end
      end
  '
}

# pm_first_stop_marker <interaction-yaml> — read the item's labels from stdin
# (one per line) and emit the first declared stop_marker present among them, or
# nothing. Empty output (with exit 0) means "not held — routing may proceed"; a
# non-empty line is the brake the router should name in its skip log.
#
# Matching is whole-line, newline-delimited on both sides — mirroring
# hold-gate.sh's hold_gate_first_match — so a label or marker containing spaces
# is compared as a whole (GitHub label names may contain spaces) and
# `needs-human-review` never matches `needs-human-review-later`. Declaration
# order in the contract decides which marker is reported when several are
# present.
#
# The markers are captured before the scan (not streamed via a process
# substitution) so an unparseable contract — pm_stop_markers exits non-zero —
# PROPAGATES as return 2 rather than being swallowed into "no markers". A 200
# with a corrupt body must never be read as "not held" any more than a 5xx must;
# the router runs `set -euo pipefail`, so a 2 here fails the job (fail-closed).
pm_first_stop_marker() {
  local interaction="$1" labels markers marker
  labels="$(cat)"
  markers="$(pm_stop_markers "$interaction")" || return 2
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    case $'\n'"${labels}"$'\n' in
      *$'\n'"${marker}"$'\n'*) printf '%s\n' "$marker"; return 0 ;;
    esac
  done <<<"$markers"
  return 0
}

# ----------------------------------------------------------------------------
# Event-surface routing — serving the pull_request surface (#1165)
# ----------------------------------------------------------------------------
# The router also serves event surfaces (starting with pull_request), delivering
# a persona's PR-advisory through the one published ingress path instead of a
# second, repo-local runtime (solution-architect decision (b), ADR-0007: one
# agent-ingress stub per repo). WHICH personas fire is DERIVED from each
# manifest's declared surfaces (#756), so enabling another persona needs no edit
# here. Every brake the mention path binds — stop markers, opt-out, the
# write-mode gate, the trust floor, and the two recursion axes — binds on this
# path too: a PR event must never become an ungated, un-held write surface.
#
# These functions are pure and take an EXPLICITLY declared surface. Unlike
# pm_mention_decision they do NOT fall back to triggers.default_mode: an event
# surface fires only when the manifest declares that surface enabled. Applying
# default_mode here would enumerate every advisory persona onto every event —
# the opposite of deriving from declared surfaces.

# pm_surface_decision <manifest-yaml> <surface> — emit "<enabled> <mode>
# <opt_out_label>" for the named surface. An absent surface row is "false off"
# (not dispatched); a declared row reports its own enabled/mode.
pm_surface_decision() {
  local manifest="$1" surface="$2" result
  # shellcheck disable=SC2016  # $surface/$t/$s/$row are jq variables, not shell
  result="$(printf '%s' "$manifest" | pm_manifest_query '
    (.triggers // {}) as $t
    | ($t.surfaces // []) as $s
    | ($s | map(select(.surface == $surface)) | first) as $row
    | (if $row == null
       then "false off"
       else ((($row.enabled // false) | tostring) + " " + ($row.mode // "advisory"))
       end) as $decision
    | $decision + " " + ($t.opt_out_label // "")
  ' --arg surface "$surface")" || return 2
  printf '%s' "$result"
}

# pm_surface_trust_floor <manifest-yaml> <surface> — emit the floor for the named
# surface, space-separated. A per-surface trust_floor tightens the persona-wide
# trust.author_association_floor; when absent, the persona-wide floor applies.
# When both are declared, intersect them (keep only values in both).
# Emits nothing when neither is declared — pm_trust_ok then denies, the safe
# direction.
pm_surface_trust_floor() {
  local manifest="$1" surface="$2" result
  # shellcheck disable=SC2016  # $surface/$row are jq variables, not shell
  result="$(printf '%s' "$manifest" | pm_manifest_query '
    ((.triggers.surfaces // []) | map(select(.surface == $surface)) | first) as $row
    | .trust.author_association_floor as $global_floor
    | $row.trust_floor as $surface_floor
    | (
        if ($surface_floor | type) == "array" and ($global_floor | type) == "array"
        then
          # Both declared: intersect them
          ($surface_floor | map(. as $x | select($global_floor[] == $x)))
        elif ($surface_floor | type) == "array"
        then
          # Only surface floor
          $surface_floor
        elif ($global_floor | type) == "array"
        then
          # Only global floor
          $global_floor
        else
          # Neither
          []
        end
      )
    | join(" ")
  ' --arg surface "$surface")" || return 2
  printf '%s' "$result"
}

# pm_surface_gate_label <manifest-yaml> <surface> — the label that ARMS a
# write-mode surface, or empty. §4 rule 2 makes gate_label schema-required when
# mode == write; the schema enforces it is DECLARED, the caller must enforce it
# is APPLIED.
pm_surface_gate_label() {
  local manifest="$1" surface="$2" result
  # shellcheck disable=SC2016  # $surface/$row are jq variables, not shell
  result="$(printf '%s' "$manifest" | pm_manifest_query '
    ((.triggers.surfaces // []) | map(select(.surface == $surface)) | first) as $row
    | ($row.gate_label // "")
  ' --arg surface "$surface")" || return 2
  printf '%s' "$result"
}

# pm_surface_declares_event <manifest-yaml> <surface> <action> — 0 only when the
# named surface row's `events` list contains <action>, 1 otherwise.
#
# `enabled` says the surface is live; `events` says WHICH event actions it fires
# on. A row that declares `events: [opened, ready_for_review]` must NOT fire on
# the `synchronize`/`reopened` the caller stub also delivers — the router derives
# the firing actions from the manifest, it does not fan every subscribed event
# onto every enabled surface. A row with NO `events` list is undeclared for every
# action and returns 1: derive from what is declared, the same fail-closed rule as
# the no-default_mode fallback (a surface must opt IN to an action, never inherit
# it). Returns 2 on an unparseable manifest so the caller fails closed (skip),
# never dispatching on a manifest it could not read.
pm_surface_declares_event() {
  local manifest="$1" surface="$2" action="$3" result
  # shellcheck disable=SC2016  # $surface/$action/$row are jq variables, not shell
  result="$(printf '%s' "$manifest" | pm_manifest_query '
    ((.triggers.surfaces // []) | map(select(.surface == $surface)) | first) as $row
    | (($row.events // [])
       | if (type == "array") and (index($action) != null) then "yes" else "no" end)
  ' --arg surface "$surface" --arg action "$action")" || return 2
  [[ "$result" = "yes" ]]
  return $?
}

# pm_persona_runtime_reusable <manifest-yaml> — print `.runtime.reusable`, or
# nothing when the manifest declares none. A persona with its own reusable
# workflow (dev-lead, pr-review) is served by that workflow on PRs, so the
# router must not dispatch it. Returns 2 on an unparseable manifest so the
# caller fails closed, same as pm_surface_decision.
pm_persona_runtime_reusable() {
  local manifest="$1" result
  result="$(printf '%s' "$manifest" | pm_manifest_query '
    ((.runtime // {}) | if type == "object" then (.reusable // "") else "" end)
    | if type == "string" then . else "" end
  ')" || return 2
  printf '%s' "$result"
}

# pm_pr_should_route <author> <actor> <author_association> <body> — 0 if a
# pull_request event is worth acting on. The CHEAP pre-filter for the PR path,
# mirrored from pm_should_route but WITHOUT the @-mention requirement: a PR
# persona is derived from manifests, never addressed in the body. Both recursion
# axes and the conservative §4 default floor still apply, so this path is no
# laxer than the mention path's pre-filter (AC #4).
#
# Recursion axis 1 checks BOTH identities, not just the PR author.
# `pull_request.user.login` is the PR's original author and never changes once
# the PR is opened; the ACTOR of a `synchronize`/`reopened` event is whoever
# pushed the update or reopened the PR. An agent pushing a commit to a human's
# PR keeps a human author but is a bot actor — checking the author alone lets
# that agent update re-trigger the router and dispatch personas again (the
# codeant/tier-3 finding). Excluding a bot on EITHER identity closes it.
pm_pr_should_route() {
  local author="$1" actor="$2" assoc="$3" body="$4"

  pm_is_bot_actor "$author" && return 1       # axis 1a: bot PR author
  pm_is_bot_actor "$actor" && return 1        # axis 1b: bot pusher/reopener (github.actor)
  pm_is_agent_comment "$body" && return 1     # axis 2: agent marker
  pm_trust_ok "$assoc" OWNER MEMBER COLLABORATOR || return 1
  return 0
}

# pm_pr_route_verdict <manifest-yaml> <interaction-yaml> <author_association> —
# read the item's labels from stdin (one per line) and decide the verdict for
# ONE persona on the pull_request surface. The caller has already established
# that the persona DECLARES the surface enabled and is not opted out (both cheap,
# label-free / manifest-only checks); this composes the remaining, label-and-
# contract-dependent gauntlet in the SAME precedence the mention path uses:
#
#   stop marker  -> "skip stop-marker <marker>"   (the human hold, AC #2)
#   write gate   -> "skip not-armed <gate>"       (unarmed write, AC #4)
#   trust floor  -> "skip below-floor"            (author below the persona floor)
#   otherwise    -> "dispatch <mode>"
#
# Fails CLOSED (non-zero, no dispatch) rather than emitting a verdict when:
#   - the interaction contract is unreadable/malformed — return 2. The contract
#     is passed already-fetched; a non-200/404 fetch is the caller's to fail on
#     (pm_fetch_disposition), but a 200 with a corrupt body surfaces here as a
#     non-zero from pm_first_stop_marker and must PROPAGATE, never be read as
#     "not held".
#   - a write surface declares no gate_label — return 3. That is a schema
#     violation validate-personas.py should have caught; dispatching it would be
#     the ungated write AC #4 forbids.
pm_pr_route_verdict() {
  local manifest="$1" interaction="$2" assoc="$3"
  local labels held decision mode gate floor

  labels="$(cat)"

  # Human hold first among the label-derived brakes. An unparseable contract
  # makes pm_first_stop_marker exit non-zero — propagate it (fail closed).
  held="$(printf '%s\n' "$labels" | pm_first_stop_marker "$interaction")" || return 2
  [[ -n "$held" ]] && {
    printf 'skip stop-marker %s\n' "$held"
    return 0
  }

  # Capture the decision first so a manifest parse/query failure propagates
  # (fail closed) instead of being swallowed by the pipe into awk; then split
  # the "<enabled> <mode> <gate:hold>" tuple with native read.
  decision="$(pm_surface_decision "$manifest" pull_request)" || return 2
  read -r _ mode _ <<<"$decision"

  if [[ "$mode" = "write" ]]; then
    gate="$(pm_surface_gate_label "$manifest" pull_request)" || return 2
    if [[ -z "$gate" ]]; then
      return 3   # write with no gate_label — schema violation; never dispatch
    fi
    if ! printf '%s\n' "$labels" | grep -qxF -- "$gate"; then
      printf 'skip not-armed %s\n' "$gate"
      return 0
    fi
  fi

  floor="$(pm_surface_trust_floor "$manifest" pull_request)" || return 2
  # shellcheck disable=SC2086  # word-splitting is the point: floor is a set
  if ! pm_trust_ok "$assoc" $floor; then
    printf 'skip below-floor\n'
    return 0
  fi

  printf 'dispatch %s\n' "$mode"
  return 0
}
