#!/usr/bin/env bats
# Guard: every required status check in this repo reports on a merge queue.
#
# A GitHub merge queue merges a PR only once each REQUIRED check has reported on
# the queue's temporary `gh-readonly-queue/*` ref, and a workflow reports there
# only if it triggers on `merge_group`. One required check without the trigger is
# enough to stop every merge: the entry waits out the queue's check timeout and
# is ejected.
#
# The required contexts are read from standards/rulesets/code-quality.json, so a
# context added to the ruleset without a `merge_group` provider registered here
# fails this suite before it can reach a live queue.
#
# Sibling guard for the caller-stub TEMPLATES other repos adopt:
# test/scripts/standards-templates/merge-group-required-checks.bats.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF_DIR="${REPO_ROOT}/.github/workflows"
RULESET="${REPO_ROOT}/standards/rulesets/code-quality.json"

# required-check context | providing workflow | line that pins the context
#
# The third field is the line whose presence produces the context, WITH its
# indentation: a job-level `name:` (4 spaces) for a plain job, the job id
# (2 spaces) for a reusable-workflow caller (GitHub composes
# `<caller job id> / <reusable job name>`). The indentation is what ties the
# line to a job: the workflow-level `name: CodeQL` sits at column 0 and must not
# satisfy the check. Renaming a job silently un-requires its check, because the
# ruleset matches by context name.
# Fields are split on the first two `|` only, so the third may hold any text.
PROVIDERS=(
  "SonarCloud|sonarcloud.yml|    name: SonarCloud"
  "CodeQL|codeql.yml|    name: CodeQL"
  "agent-shield / AgentShield|agent-shield.yml|  agent-shield:"
  "dependency-audit / Detect ecosystems|dependency-audit.yml|  dependency-audit:"
)

# Print the `merge_group:` trigger line ONLY when it is a direct child of the
# top-level `on:` block — never a key nested under another trigger, a comment,
# or a prose mention. Same matcher as the standards-templates guard.
merge_group_lines() {
  awk '
    /^on:[[:space:]]*$/       { in_on = 1; child = 0; next }
    /^[^[:space:]#]/          { in_on = 0 }
    in_on && /^[[:space:]]*#/ { next }
    in_on && /^[ ]+[^[:space:]]/ {
      match($0, /^[ ]+/); ind = RLENGTH
      if (child == 0) child = ind
      if (ind == child && $0 ~ /^[ ]+merge_group:[[:space:]]*$/)
        print FNR ":" $0
    }
  ' "$1"
}

# Succeeds when <file> has a line equal to <line>, indentation included, once a
# trailing comment and trailing whitespace are ignored.
has_line() {
  local file="$1" line="$2"
  sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' "$file" | grep -Fxq -- "$line"
}

required_contexts() {
  jq -r '.rules[] | select(.type == "required_status_checks")
         | .parameters.required_status_checks[].context' "$RULESET"
}

@test "every required context in the ruleset has a registered provider" {
  local missing=() ctx entry found
  while IFS= read -r ctx; do
    found=0
    for entry in "${PROVIDERS[@]}"; do
      [ "${entry%%|*}" = "$ctx" ] && found=1
    done
    [ "$found" -eq 1 ] || missing+=("$ctx")
  done < <(required_contexts)
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'required context with no provider registered in PROVIDERS -> %s\n' "${missing[@]}"
    return 1
  fi
}

@test "every provider workflow triggers on merge_group" {
  local violations=() entry rest wf f
  for entry in "${PROVIDERS[@]}"; do
    rest="${entry#*|}"; wf="${rest%%|*}"
    f="${WF_DIR}/${wf}"
    [ -f "$f" ] || { violations+=("${wf}: workflow missing"); continue; }
    [ -n "$(merge_group_lines "$f")" ] || violations+=("${wf}: no top-level 'merge_group:' trigger in on: block")
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'missing merge_group trigger -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "every provider workflow still produces its required context name" {
  local violations=() entry rest ctx wf line f
  for entry in "${PROVIDERS[@]}"; do
    ctx="${entry%%|*}"; rest="${entry#*|}"
    wf="${rest%%|*}"; line="${rest#*|}"
    f="${WF_DIR}/${wf}"
    [ -f "$f" ] || { violations+=("${wf}: workflow missing"); continue; }
    has_line "$f" "$line" || violations+=("${wf}: line '${line}' (context '${ctx}') not found")
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'required-check context drift -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "the merge_group trigger carries no branch or path filter" {
  # A filtered trigger can skip the workflow for some queue entries, which leaves
  # the required check unreported for exactly those entries.
  local violations=() entry rest wf f
  for entry in "${PROVIDERS[@]}"; do
    rest="${entry#*|}"; wf="${rest%%|*}"
    f="${WF_DIR}/${wf}"
    [ -f "$f" ] || continue
    if awk '
      /^  merge_group:[[:space:]]*$/ { seen = 1; next }
      seen && /^[[:space:]]*(#.*)?$/  { next }
      seen { if ($0 ~ /^    [^[:space:]]/) bad = 1; seen = 0 }
      END { exit bad ? 0 : 1 }
    ' "$f"; then
      violations+=("${wf}: merge_group has nested keys")
    fi
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'filtered merge_group trigger -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "codeql.yml analyses the languages default setup covered" {
  grep -Eq '^[[:space:]]+language:[[:space:]]*\[actions,[[:space:]]*python\][[:space:]]*$' "${WF_DIR}/codeql.yml"
}

@test "the SonarCloud scan names the base branch on a merge queue run" {
  # Without it every queued PR is recorded as a new branch in SonarCloud.
  local f="${WF_DIR}/sonarcloud.yml" n
  grep -Fq 'github.event.merge_group.base_ref' "$f"
  n="$(grep -c -- '-Dsonar.branch.name=' "$f")"
  # Both the first scan and its retry must pass the argument.
  [ "$n" -eq 2 ] || { echo "expected sonar.branch.name on scan and retry, found ${n}"; return 1; }
}

@test "a workflow-level name does not stand in for a renamed job" {
  # codeql.yml is also NAMED `CodeQL` at workflow level. That line must not
  # satisfy the context check once the job itself is renamed.
  local renamed
  renamed="$(mktemp)"
  printf 'name: CodeQL\non:\n  merge_group:\njobs:\n  CodeQL:\n    name: Code scanning\n    runs-on: ubuntu-latest\n' > "$renamed"
  if has_line "$renamed" "    name: CodeQL"; then
    rm -f "$renamed"; echo "workflow-level name matched as a job name"; return 1
  fi
  printf 'name: CodeQL\non:\n  merge_group:\njobs:\n  CodeQL:\n    name: CodeQL  # required context\n    runs-on: ubuntu-latest\n' > "$renamed"
  has_line "$renamed" "    name: CodeQL" || { rm -f "$renamed"; echo "job-level name not matched"; return 1; }
  rm -f "$renamed"
}

@test "matchers reject a nested trigger and a filtered trigger" {
  # Negative controls, so the checks above cannot pass vacuously.
  local nested filtered
  nested="$(mktemp)"; filtered="$(mktemp)"
  printf 'on:\n  push:\n    branches: [main]\n    merge_group:\njobs:\n  x:\n    runs-on: ubuntu-latest\n' > "$nested"
  printf 'on:\n  push:\n    branches: [main]\n  merge_group:\n    branches: [main]\njobs:\n  x:\n    runs-on: ubuntu-latest\n' > "$filtered"
  [ -z "$(merge_group_lines "$nested")" ]   || { echo "nested merge_group wrongly matched"; rm -f "$nested" "$filtered"; return 1; }
  [ -n "$(merge_group_lines "$filtered")" ] || { echo "top-level merge_group not matched"; rm -f "$nested" "$filtered"; return 1; }
  rm -f "$nested" "$filtered"
  [ "$(required_contexts | wc -l)" -ge 4 ] || { echo "expected >=4 required contexts in the ruleset"; return 1; }
}
