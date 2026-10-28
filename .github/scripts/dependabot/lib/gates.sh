#!/usr/bin/env bash
# Merge / approval gates for the Dependabot reusables (issues #1399, #1400).
#
# Pure decisions: no network calls, no sleeps. Each gate takes the JSON the
# I/O glue (lib/gh-io.sh) fetched, prints a one-line reason, and returns
#   0  pass   — safe to approve / merge the PR at the verified head SHA
#   1  block  — skip the PR (fail closed); the reason says why
# Malformed or missing input always blocks.
#
# Tested by test/workflows/dependabot/gates.bats.
# Contract: see .github/scripts/dependabot/README.md

# Logins GitHub attributes to genuine Dependabot commits. Dependabot commits are
# authored by dependabot[bot] and committed by GitHub (`web-flow`) with a
# GitHub-verified signature.
DEPENDABOT_LOGIN="dependabot[bot]"

# dependabot_checks_gate PR_JSON REQUIRED_JSON [EXPECTED_SHA]
#   PR_JSON      GraphQL `pullRequest` object (or the whole `{data:{repository:
#                {pullRequest:…}}}` response) with headRefOid and
#                commits(last:1){nodes{commit{oid statusCheckRollup{contexts{
#                pageInfo{hasNextPage} nodes{CheckRun{name status conclusion}
#                StatusContext{context state}}}}}}}.
#   REQUIRED_JSON  JSON array of check names the base branch's rules require
#                (`[]` when none).
#   EXPECTED_SHA  optional — block unless the PR head is this commit.
#
#   Passes only when every check run on the head commit COMPLETED as success,
#   neutral or skipped, every commit status is success, at least one check was
#   reported, and every required check name is present. Anything else —
#   failure, cancelled, timed_out, action_required, stale, startup_failure,
#   pending, missing, or more contexts than one page — blocks.
dependabot_checks_gate() {
  local pr_json="$1" required_json="${2:-[]}" expected="${3:-}" out verdict reason

  out=$(jq -r --argjson required "$required_json" --arg expected "$expected" '
    (if has("data") then .data.repository.pullRequest else . end) as $pr
    | ($pr.headRefOid // "") as $head
    | ($pr.commits.nodes[0].commit // {}) as $commit
    | ($commit.statusCheckRollup.contexts // null) as $ctx
    | ($ctx.nodes // []) as $nodes
    | def name_of: if .__typename == "StatusContext" then (.context // "")
                   else (.name // "") end;
      def ok: if .__typename == "CheckRun" then
                ((.status // "" | ascii_upcase) == "COMPLETED")
                and ((.conclusion // "" | ascii_upcase)
                     | IN("SUCCESS", "NEUTRAL", "SKIPPED"))
              elif .__typename == "StatusContext" then
                ((.state // "" | ascii_upcase) == "SUCCESS")
              else false end;
      def outcome: if .__typename == "StatusContext" then (.state // "MISSING")
                   elif ((.status // "" | ascii_upcase) != "COMPLETED") then (.status // "MISSING")
                   else (.conclusion // "MISSING") end | ascii_downcase;
      ([$nodes[] | name_of]) as $names
    | ([$required[] | select(. as $r | $names | index($r) | not)]) as $missing
    | ([$nodes[] | select(ok | not) | "\(name_of) (\(outcome))"]) as $bad
    | if $head == "" then "block\tPR head commit unknown"
      elif ($expected != "" and $head != $expected) then
        "block\thead moved to \($head[0:7]) (expected \($expected[0:7]))"
      elif ($commit.oid // "") != $head then
        "block\tcheck rollup is not for the head commit \($head[0:7])"
      elif $ctx == null or ($nodes | length) == 0 then
        "block\tno checks reported on \($head[0:7])"
      elif ($ctx.pageInfo.hasNextPage // false) then
        "block\tmore checks than fit in one page on \($head[0:7]) — cannot verify them all"
      elif ($bad | length) > 0 then
        "block\t\($bad | length) check(s) not successful on \($head[0:7]): \($bad | join(", "))"
      elif ($missing | length) > 0 then
        "block\trequired check(s) not reported on \($head[0:7]): \($missing | join(", "))"
      else
        "pass\tall \($nodes | length) check(s) succeeded on \($head[0:7])"
      end
  ' <<<"$pr_json" 2>/dev/null) || out=""

  verdict="${out%%$'\t'*}"
  reason="${out#*$'\t'}"
  if [[ "$verdict" == "pass" ]]; then
    echo "$reason"
    return 0
  fi
  if [[ "$verdict" == "block" ]]; then
    echo "$reason"
  else
    echo "could not evaluate checks (malformed input)"
  fi
  return 1
}

# dependabot_provenance_gate PR_JSON COMMITS_JSON [TRUSTED_MERGE_LOGIN] [EXPECTED_SHA]
#   PR_JSON      REST `GET /repos/{r}/pulls/{n}` object (head.sha, commits).
#   COMMITS_JSON REST `GET /repos/{r}/pulls/{n}/commits` — a flat array, or the
#                array of pages `gh api --paginate --slurp` produces.
#   TRUSTED_MERGE_LOGIN  login of the merge App (e.g. `my-app[bot]`); merge
#                commits it created through the update-branch API are allowed.
#                Empty — only Dependabot commits are allowed.
#   EXPECTED_SHA optional — block unless the PR head is this commit.
#
#   Passes only when the full commit list was read (its length equals the PR's
#   commit count and contains the head), at least one commit is Dependabot's,
#   and EVERY commit is either
#     - authored by dependabot[bot], committed by web-flow or dependabot[bot],
#       with a GitHub-verified signature; or
#     - a merge commit (2+ parents) authored by TRUSTED_MERGE_LOGIN, committed
#       by web-flow, with a GitHub-verified signature (update-branch).
#   Any other commit — e.g. one pushed to the branch by someone else — blocks.
dependabot_provenance_gate() {
  local pr_json="$1" commits_json="$2" trusted="${3:-}" expected="${4:-}" out verdict reason

  # Both documents go through stdin: a long commit list can exceed the
  # per-argument size limit of --argjson.
  out=$({ printf '%s\n' "$pr_json"; printf '%s\n' "$commits_json"; } | jq -rs \
      --arg trusted "$trusted" --arg expected "$expected" --arg bot "$DEPENDABOT_LOGIN" '
    if length != 2 then error("expected two documents") else . end
    | .[0] as $pr | .[1] as $pages
    | ($pr.head.sha // "") as $head
    | ($pr.commits // -1) as $count
    | ([$pages | if type == "array" then flatten[] else empty end
        | select(type == "object")]) as $commits
    | def verified: (.commit.verification.verified // false) == true;
      def author: (.author.login // "");
      def committer: (.committer.login // "");
      def from_dependabot:
        author == $bot and (committer | IN("web-flow", $bot)) and verified;
      def trusted_merge:
        $trusted != "" and author == $trusted and committer == "web-flow"
        and ((.parents // []) | length) >= 2 and verified;
      ([$commits[] | select((from_dependabot or trusted_merge) | not)
        | "\(.sha // "?" | .[0:7]) (author \(author | if . == "" then "unknown" else . end), committer \(committer | if . == "" then "unknown" else . end)\(if verified then "" else ", unverified" end))"]) as $foreign
    | if $head == "" then "block\tPR head commit unknown"
      elif ($expected != "" and $head != $expected) then
        "block\thead moved to \($head[0:7]) (expected \($expected[0:7]))"
      elif ($commits | length) == 0 then "block\tno commits read"
      elif ($commits | length) != $count then
        "block\tread \($commits | length) of \($count) commits — cannot verify them all"
      elif ([$commits[] | .sha] | index($head)) == null then
        "block\thead \($head[0:7]) not in the commit list"
      elif ($foreign | length) > 0 then
        "block\t\($foreign | length) commit(s) not from Dependabot: \($foreign | join(", "))"
      elif ([$commits[] | select(from_dependabot)] | length) == 0 then
        "block\tno Dependabot commit on the PR"
      else
        "pass\tall \($commits | length) commit(s) from Dependabot\(if $trusted != "" then " or \($trusted) branch updates" else "" end) (head \($head[0:7]))"
      end
  ' 2>/dev/null) || out=""

  verdict="${out%%$'\t'*}"
  reason="${out#*$'\t'}"
  if [[ "$verdict" == "pass" ]]; then
    echo "$reason"
    return 0
  fi
  if [[ "$verdict" == "block" ]]; then
    echo "$reason"
  else
    echo "could not evaluate commit provenance (malformed input)"
  fi
  return 1
}

# dependabot_required_contexts RULES_JSON
#   RULES_JSON  REST `GET /repos/{r}/rules/branches/{b}` — a flat array of
#               rules or the array of pages `--paginate --slurp` produces.
#   Prints a JSON array of the unique required status-check names. Returns 1
#   (printing nothing) when the input is not an array.
dependabot_required_contexts() {
  local rules_json="$1" out
  out=$(jq -c '
    if type != "array" then error("not an array") else . end
    | [flatten[] | select(type == "object" and .type == "required_status_checks")
       | (.parameters.required_status_checks // [])[] | .context
       | select(type == "string" and . != "")] | unique
  ' <<<"$rules_json" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  echo "$out"
}
