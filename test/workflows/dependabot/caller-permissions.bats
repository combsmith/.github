#!/usr/bin/env bats
# A reusable workflow's jobs cannot get more GITHUB_TOKEN permissions than the
# calling job grants; asking for more fails the run at startup. Pin that every
# permission the Dependabot reusables request is granted by each caller: this
# repo's own stubs and the standards templates copied to every org repo
# (#1399 review).

load 'helpers/setup'

WF="${TT_REPO_ROOT}/.github/workflows"
STD="${TT_REPO_ROOT}/standards/workflows"

setup() {
  tt_setup
}

teardown() {
  tt_teardown
}

# _assert_caller_grants CALLER — every permission each job of the reusable the
# caller's job uses requests is granted by that job (write covers read).
_assert_caller_grants() {
  local caller="$1" job uses reusable granted requested scope level have
  for job in $(yq -r '.jobs | keys | .[]' "$caller"); do
    uses=$(yq -r ".jobs.\"${job}\".uses // \"\"" "$caller")
    [[ "$uses" == *dependabot-*-reusable.yml* ]] || continue
    reusable="${WF}/$(basename "${uses%%@*}")"
    [ -f "$reusable" ] || { echo "$caller: $uses not found"; return 1; }
    granted=$(yq -o=json -I0 ".jobs.\"${job}\".permissions // {}" "$caller")
    requested=$(yq -o=json -I0 '[.jobs[].permissions // {} | to_entries[]]' "$reusable")
    while IFS=$'\t' read -r scope level; do
      [[ -n "$scope" ]] || continue
      have=$(jq -r --arg s "$scope" '.[$s] // "none"' <<<"$granted")
      if [[ "$level" == "write" && "$have" != "write" ]] \
          || [[ "$level" == "read" && "$have" != "read" && "$have" != "write" ]]; then
        echo "$caller grants ${scope}: ${have}; $(basename "$reusable") requests ${scope}: ${level}"
        return 1
      fi
    done < <(jq -r '.[] | [.key, .value] | @tsv' <<<"$requested")
  done
}

@test "callers: this repo's dependabot-rebase stub grants what the reusable requests" {
  _assert_caller_grants "${WF}/dependabot-rebase.yml"
}

@test "callers: the dependabot-rebase template grants what the reusable requests" {
  _assert_caller_grants "${STD}/dependabot-rebase.yml"
}

@test "callers: this repo's dependabot-automerge stub grants what the reusable requests" {
  _assert_caller_grants "${WF}/dependabot-automerge.yml"
}

@test "callers: the dependabot-automerge template grants what the reusable requests" {
  _assert_caller_grants "${STD}/dependabot-automerge.yml"
}

@test "callers: the check catches a reusable that asks for more than its caller grants" {
  local fake="${TT_TMP}/caller.yml"
  printf 'jobs:\n  r:\n    permissions:\n      contents: read\n    uses: ./.github/workflows/dependabot-rebase-reusable.yml\n' > "$fake"
  run _assert_caller_grants "$fake"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requests pull-requests: read"* ]]
}
