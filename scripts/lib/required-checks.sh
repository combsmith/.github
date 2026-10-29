# shellcheck shell=bash
# scripts/lib/required-checks.sh — repo-declared additional required checks
#
# The standard (standards/github-settings.md#repo-declared-required-checks) lets
# a repo require status checks beyond the four codified in
# standards/rulesets/code-quality.json by declaring them in its own
# `.github/required-checks.json`:
#
#   {"version": 1,
#    "required_status_checks": [{"context": "mutation (all)", "integration_id": 15368}]}
#
# Every entry carries an `integration_id`, so the check is pinned to the app that
# must report it (a declared check cannot be satisfied by another app's status).
#
# The declaration is an ALLOWLIST, not "whatever is live": apply-rulesets.sh merges
# exactly the declared entries into the code-quality payload it PUTs, so a stale or
# hand-added live context is still converged away, and the compliance audit flags a
# declared entry that is missing from the live ruleset. This library holds the
# pure functions both sides use, so they cannot disagree:
#
#   rc_declared_checks   — validate a declaration, emit its normalised check array.
#   rc_merge_payload     — codified payload + declared checks → payload to PUT.
#   rc_missing_from_live — declared checks the live ruleset does not enforce.
#   rc_drop_codified     — declared checks minus those the codified payload owns.
#
# All three are pure: JSON in, text out, no gh calls. This library is
# `set -euo pipefail`-safe and does not call `set` itself.

# The path, relative to a repo's root, of its declaration (read from the
# default branch, so a declaration only takes effect once it is merged).
# shellcheck disable=SC2034  # read by apply-rulesets.sh and compliance-audit.sh
readonly RC_DECLARED_PATH=".github/required-checks.json"

# rc_declared_checks <declaration_json>
#   Validate a `.github/required-checks.json` document and echo its
#   `required_status_checks` array (compact JSON). Exit non-zero, with the reason
#   on stderr, when the document is not valid: wrong shape, an unknown `version`,
#   an entry with an empty `context`, a missing or non-integer `integration_id`,
#   an unknown key, or a duplicate context. Fail closed: a declaration the applier
#   cannot trust must never be read as "no extra checks".
rc_declared_checks() {
  local doc="$1" out
  # shellcheck disable=SC2016  # jq program text
  out="$(jq -c '
    def fail($m): error($m);
    # check(cond; msg): pass the input through unchanged unless cond holds.
    def check(bad; $m): if bad then fail($m) else . end;
    if type != "object" then fail("declaration must be a JSON object")
    elif .version != 1 then fail("unsupported version \(.version | tojson) (expected 1)")
    elif (.required_status_checks | type) != "array" then fail("required_status_checks must be an array")
    else
      .required_status_checks
      | check(any(.[]; type != "object"); "every entry must be an object")
      | check(any(.[]; (keys - ["context","integration_id"]) | length > 0);
              "unknown key in an entry; allowed: context, integration_id")
      | check(any(.[]; (.context | type) != "string" or (.context | length) == 0);
              "every entry needs a non-empty string context")
      | check(any(.[]; (.integration_id | type) != "number" or (.integration_id | floor) != .integration_id or .integration_id <= 0);
              "every entry needs a positive integer integration_id (the app that must report it)")
      | check((map(.context) | length) != (map(.context) | unique | length);
              "duplicate context(s): \(group_by(.context) | map(select(length > 1) | .[0].context) | join(", "))")
      | map({context, integration_id})
    end
  ' <<< "$doc" 2>&1)" || { printf '%s\n' "${out#jq: error (at <stdin>:*): }" >&2; return 1; }
  # An empty or whitespace-only document makes jq read no input and exit 0 with
  # no output; reject it explicitly so it can't pass as valid.
  [ -n "$out" ] || { echo "declaration is empty" >&2; return 1; }
  printf '%s\n' "$out"
}

# rc_merge_payload <payload_json> <declared_checks_json>
#   Echo the ruleset payload (compact JSON) with every declared check appended to
#   its `required_status_checks` rule, after the codified contexts. A declared
#   context that is already codified is skipped, so the codified entry always
#   wins. Every other rule and field is unchanged; with no declared checks the
#   output equals the input.
rc_merge_payload() {
  local payload="$1" declared="$2"
  jq -c --argjson d "$declared" '
    .rules |= map(
      if .type == "required_status_checks" then
        ([.parameters.required_status_checks[]?.context]) as $have
        | .parameters.required_status_checks += [ $d[] | select(.context as $c | $have | index($c) | not) ]
      else . end)
  ' <<< "$payload"
}

# rc_drop_codified <payload_json> <declared_checks_json>
#   Echo the declared checks (compact JSON) minus those whose context is already
#   codified in the payload's `required_status_checks` rule. rc_merge_payload
#   keeps the codified entry in that case, so the audit must not demand the
#   declaration's app pin for it (check_ruleset_contents audits codified entries).
rc_drop_codified() {
  local payload="$1" declared="$2"
  jq -c --argjson d "$declared" '
    ([.rules[]? | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]?.context]) as $have
    | [ $d[] | select(.context as $c | $have | index($c) | not) ]
  ' <<< "$payload"
}

# rc_missing_from_live <declared_checks_json> <live_ruleset_json>
#   Echo one TSV line per declared check the live ruleset does not enforce as
#   declared:  <context> TAB <declared integration_id> TAB <live state>
#   where <live state> is `missing` (context absent) or the live integration_id
#   (`any` when the live entry is not pinned to an app). Nothing when every
#   declared check is live with its app.
rc_missing_from_live() {
  local declared="$1" live="$2"
  jq -rn --argjson d "$declared" --argjson live "$live" '
    [ $live.rules[]? | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]? ] as $l
    | $d[]
    | . as $want
    | ([ $l[] | select(.context == $want.context) ]) as $hits
    | if ($hits | length) == 0 then [ $want.context, ($want.integration_id | tostring), "missing" ]
      elif ($hits | map(.integration_id) | index($want.integration_id)) != null then empty
      else [ $want.context, ($want.integration_id | tostring), ($hits[0].integration_id // "any" | tostring) ]
      end
    | @tsv
  '
}
