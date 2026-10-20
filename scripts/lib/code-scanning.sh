# shellcheck shell=bash
# scripts/lib/code-scanning.sh — the code-scanning merge-protection floor
#
# The org standard (standards/github-settings.md#code-scanning-merge-protection-all-repositories)
# protects every default branch with a `code_scanning` ruleset rule. Its desired
# state is codified in standards/rulesets/code-quality.json:
#
#   {"tool":"CodeQL","security_alerts_threshold":"medium_or_higher","alerts_threshold":"errors"}
#
# That value is a FLOOR, not an exact match: a repo that gates on more (e.g.
# `security_alerts_threshold: all`) is compliant and must never be "fixed" down.
# This library holds the one ordering of GitHub's threshold values and the two
# pure functions that use it, so the audit and the applier cannot disagree:
#
#   scripts/compliance-audit.sh  — cs_floor_shortfall: which floor parameters the
#                                  default branch's effective rules fall short of.
#   scripts/apply-rulesets.sh    — cs_floor_payload: the codified ruleset with any
#                                  stricter live threshold kept, so a PUT never
#                                  lowers one.
#
# Both are pure: JSON in, text out, no gh calls. This library is
# `set -euo pipefail`-safe and does not call `set` itself.

# jq definitions: rank each threshold value, weakest first. GitHub's values
# (REST `code_scanning_tools[]`):
#   security_alerts_threshold: none < critical < high_or_higher < medium_or_higher < all
#   alerts_threshold:          none < errors < errors_and_warnings < all
# An unknown value ranks -1, below `none`: the audit reads it as short of the
# floor (fail closed) and the applier never keeps it.
# shellcheck disable=SC2016  # jq program text, not shell expansions
CS_RANK_JQ='
  def cs_rank($field):
    if $field == "security_alerts_threshold" then
      ({"none":0,"critical":1,"high_or_higher":2,"medium_or_higher":3,"all":4}[. // ""] // -1)
    else
      ({"none":0,"errors":1,"errors_and_warnings":2,"all":3}[. // ""] // -1)
    end;
  def cs_fields: ["security_alerts_threshold", "alerts_threshold"];
'

# cs_floor_tools <ruleset_file>
#   Echo the codified `code_scanning_tools` array (compact JSON) of the ruleset
#   file, or nothing when it carries no code_scanning rule or cannot be parsed.
cs_floor_tools() {
  jq -c '[.rules[]? | select(.type == "code_scanning") | .parameters.code_scanning_tools[]?]
         | if length > 0 then . else empty end' "$1" 2>/dev/null || true
}

# cs_floor_shortfall <floor_tools_json> <branch_rules_json>
#   <floor_tools_json>  — the codified tools array (cs_floor_tools).
#   <branch_rules_json> — the rules that apply to the default branch, as
#                         GET repos/{owner}/{repo}/rules/branches/{branch} returns
#                         them: one entry per rule per active ruleset.
#   Echo one TSV line per floor parameter the branch falls short of:
#     <tool> TAB missing TAB - TAB -
#     <tool> TAB <field> TAB <floor value> TAB <effective value>
#   and nothing when the branch meets or exceeds the floor.
#
#   Rulesets layer: GitHub enforces every active ruleset's rule, so when several
#   carry a code_scanning entry for the same tool, each field's effective value
#   is the strictest of them. Exit status is jq's; a caller treats failure as
#   "could not compare", never as "no shortfall".
cs_floor_shortfall() {
  local floor="$1" rules="$2"
  jq -rn --argjson floor "$floor" --argjson rules "$rules" "$CS_RANK_JQ"'
    $floor[] as $f
    | [ $rules[]? | select(.type == "code_scanning")
        | .parameters.code_scanning_tools[]? | select(.tool == $f.tool) ] as $live
    | if ($live | length) == 0 then
        [ $f.tool, "missing", "-", "-" ]
      else
        cs_fields[] as $k
        | ($f[$k]) as $want
        | ([ $live[] | .[$k] ] | max_by(cs_rank($k))) as $have
        | select(($have | cs_rank($k)) < ($want | cs_rank($k)))
        | [ $f.tool, $k, $want, ($have // "unset") ]
      end
    | @tsv
  '
}

# cs_floor_payload <ruleset_file> <live_ruleset_json>
#   Echo the codified ruleset (compact JSON) to PUT, with every code_scanning
#   threshold raised to the live ruleset's value for the same tool where the live
#   one is stricter. Everything else is the codified file, unchanged. With no
#   live code_scanning rule (or an empty live ruleset) the output is the file.
cs_floor_payload() {
  local file="$1" live="$2"
  jq -c --argjson live "$live" "$CS_RANK_JQ"'
    [ $live.rules[]? | select(.type == "code_scanning")
      | .parameters.code_scanning_tools[]? ] as $lt
    | .rules |= map(
        if .type == "code_scanning" then
          .parameters.code_scanning_tools |= map(
            . as $t
            | reduce cs_fields[] as $k ($t;
                ([ $lt[] | select(.tool == $t.tool) | .[$k] ] | max_by(cs_rank($k))) as $l
                | if ($l | cs_rank($k)) > (.[$k] | cs_rank($k)) then .[$k] = $l else . end))
        else . end)
  ' "$file"
}
