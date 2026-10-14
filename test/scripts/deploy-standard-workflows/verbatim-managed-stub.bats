#!/usr/bin/env bats
# #1277 — a verbatim-managed stub (initiative-driver.yml: no `-reusable.yml`
# `uses:`) is compared in FULL against its template, even though the template
# carries action-step `uses:` lines (the rate-limit gate tooling checkout). Before
# the fix, is_pin_compliant took the template's FIRST `uses:` line — the checkout
# action — as the "pin", so any stub that kept that one line passed, whatever else
# had drifted (e.g. repo-template's gate checkout still on `ref: v1`).
#
# The deploy sweep (is_already_compliant) and the compliance audit
# (check_verbatim_stubs) share the decision via scripts/lib/stub-verbatim.sh;
# every case is run through BOTH real code paths and they must agree.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
TEMPLATE="$REPO_ROOT/standards/workflows/initiative-driver.yml"

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/verbatim.XXXXXX")"
}

teardown() { rm -rf "$TT_TMP"; }

# sweep_verdict <stub-file> [repo] -> prints compliant|drift
sweep_verdict() {
  bash -c '
    source "$1/scripts/deploy-standard-workflows.sh" >/dev/null 2>&1
    set +e
    content="$(cat "$2")"
    if is_already_compliant "$content" "$1/standards/workflows/initiative-driver.yml" "$3" 2>/dev/null; then
      echo compliant
    else
      echo drift
    fi
  ' _ "$REPO_ROOT" "$1" "${2:-markets}"
}

# audit_verdict <stub-file> [repo] -> prints compliant|drift (drift = a finding)
audit_verdict() {
  bash -c '
    source "$1/scripts/compliance-audit.sh" >/dev/null 2>&1
    ORG=petry-projects
    FIXTURE_B64="$(base64 -w 0 < "$2" 2>/dev/null || base64 -b 0 < "$2")"
    # Fake gh_api: lists initiative-driver.yml, serves the fixture as its body.
    gh_api() {
      case "$1" in
        */contents/.github/workflows) printf "initiative-driver.yml\n" ;;
        */contents/.github/workflows/initiative-driver.yml) printf "%s" "$FIXTURE_B64" ;;
      esac
    }
    # Fake add_finding: prints FINDING for the verbatim-stub check only.
    add_finding() { case "$3" in verbatim-stub-drift-*) echo FINDING ;; esac; }
    out="$(check_verbatim_stubs "$3" 2>/dev/null)"
    if [ -n "$out" ]; then echo drift; else echo compliant; fi
  ' _ "$REPO_ROOT" "$1" "${2:-markets}"
}

# assert_agree <stub-file> <expected compliant|drift> [repo]
assert_agree() {
  local s a
  s="$(sweep_verdict "$1" "${3:-markets}")"
  a="$(audit_verdict "$1" "${3:-markets}")"
  echo "stub=$1 sweep=$s audit=$a expected=$2"
  [ "$s" = "$a" ]
  [ "$s" = "$2" ]
}

@test "the template still carries an action-step uses: line (the precondition of #1277)" {
  grep -qE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*actions/checkout@' "$TEMPLATE"
}

@test "byte-identical initiative-driver stub is compliant in sweep and audit" {
  cp "$TEMPLATE" "$TT_TMP/stub.yml"
  assert_agree "$TT_TMP/stub.yml" compliant
}

@test "CRLF-only difference is still compliant" {
  sed 's/$/\r/' "$TEMPLATE" > "$TT_TMP/stub.yml"
  assert_agree "$TT_TMP/stub.yml" compliant
}

@test "#1277: gate checkout on ref: v1 is drift, though the checkout uses: line matches" {
  sed -E 's/^([[:space:]]*ref:)[[:space:]].*$/\1 v1/' "$TEMPLATE" > "$TT_TMP/stub.yml"
  # Precondition: the variant still contains the template's checkout uses: line.
  grep -qF "$(grep -E '^[[:space:]]*uses:' "$TEMPLATE" | head -1)" "$TT_TMP/stub.yml"
  run cmp -s "$TEMPLATE" "$TT_TMP/stub.yml"
  [ "$status" -eq 1 ]
  assert_agree "$TT_TMP/stub.yml" drift
}

@test "#1277: a one-line non-uses: edit is drift" {
  sed 's/timeout-minutes: 5/timeout-minutes: 30/' "$TEMPLATE" > "$TT_TMP/stub.yml"
  run cmp -s "$TEMPLATE" "$TT_TMP/stub.yml"
  [ "$status" -eq 1 ]
  assert_agree "$TT_TMP/stub.yml" drift
}

@test "a stub with no gate checkout at all is drift" {
  grep -v 'actions/checkout@' "$TEMPLATE" > "$TT_TMP/stub.yml"
  assert_agree "$TT_TMP/stub.yml" drift
}

@test "audit exempts the self-managing meta-repos" {
  sed -E 's/^([[:space:]]*ref:)[[:space:]].*$/\1 v1/' "$TEMPLATE" > "$TT_TMP/stub.yml"
  [ "$(audit_verdict "$TT_TMP/stub.yml" .github)" = compliant ]
  [ "$(audit_verdict "$TT_TMP/stub.yml" .github-private)" = compliant ]
}

@test "audit is silent when the repo has no initiative-driver stub" {
  run bash -c '
    source "$1/scripts/compliance-audit.sh" >/dev/null 2>&1
    gh_api() { case "$1" in */contents/.github/workflows) printf "ci.yml\n" ;; esac; }
    add_finding() { echo FINDING; }
    check_verbatim_stubs markets
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stub_is_verbatim_managed: initiative-driver yes; every ring stub no" {
  run bash -c '
    source "$1/scripts/lib/stub-verbatim.sh"
    stub_is_verbatim_managed "$1/standards/workflows/initiative-driver.yml" || { echo "initiative-driver not verbatim"; exit 1; }
    for w in dev-lead pr-review-mention persona-mention agent-shield auto-rebase dependabot-automerge dependabot-rebase dependency-audit add-to-project pr-auto-review feature-ideation; do
      if stub_is_verbatim_managed "$1/standards/workflows/$w.yml"; then echo "$w wrongly verbatim"; exit 1; fi
    done
  ' _ "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stub_reusable_uses skips action-step uses: lines" {
  printf '%s\n' 'jobs:' '  a:' '    steps:' '      - uses: actions/checkout@abc # v7' \
    '  b:' '    uses: org/repo/.github/workflows/x-reusable.yml@x/v1-stable  # NOSONAR' > "$TT_TMP/t.yml"
  run bash -c 'source "$1/scripts/lib/stub-verbatim.sh"; stub_reusable_uses "$2"' _ "$REPO_ROOT" "$TT_TMP/t.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "org/repo/.github/workflows/x-reusable.yml@x/v1-stable" ]
  run bash -c 'source "$1/scripts/lib/stub-verbatim.sh"; stub_reusable_uses "$2"' _ "$REPO_ROOT" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stub_reusable_uses matches a reusable by its workflow path, not a -reusable suffix" {
  printf '%s\n' 'jobs:' '  a:' '    steps:' '      - uses: actions/checkout@abc' \
    '  b:' '    uses: org/repo/.github/workflows/pr-review.yml@pr-review/v1-stable' > "$TT_TMP/t.yml"
  run bash -c 'source "$1/scripts/lib/stub-verbatim.sh"; stub_reusable_uses "$2"' _ "$REPO_ROOT" "$TT_TMP/t.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "org/repo/.github/workflows/pr-review.yml@pr-review/v1-stable" ]
}

@test "audit marks the repo inconclusive (rc 0, no finding) when the workflow listing fails, under set -e" {
  run bash -c '
    source "$1/scripts/compliance-audit.sh" >/dev/null 2>&1
    set -e
    gh_api() { return 1; }
    add_finding() { echo FINDING; }
    mark_repo_inconclusive() { echo "INCONCLUSIVE $1"; }
    check_verbatim_stubs markets 2>/dev/null
    echo reached-after
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INCONCLUSIVE markets"* ]]
  [[ "$output" != *FINDING* ]]
  [[ "$output" == *reached-after* ]]
}

@test "VERBATIM_STUB_WORKFLOWS is exactly the deployable workflows with a verbatim-managed template" {
  run bash -c '
    source "$1/scripts/deploy-standard-workflows.sh" >/dev/null 2>&1
    derived=()
    for w in "${DEPLOYABLE_WORKFLOWS[@]}"; do
      stub_is_verbatim_managed "$STANDARDS_DIR/$w" && derived+=("$w")
    done
    [ "${derived[*]}" = "${VERBATIM_STUB_WORKFLOWS[*]}" ] || { echo "derived=${derived[*]} declared=${VERBATIM_STUB_WORKFLOWS[*]}"; exit 1; }
  ' _ "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "ring-managed dev-lead stub keeps the ring-pin rule (body edits are not verbatim drift)" {
  run bash -c '
    source "$1/scripts/deploy-standard-workflows.sh" >/dev/null 2>&1
    set +e
    gh() { case "$2" in *matching-refs/tags/*) printf "refs/tags/dev-lead/v139-stable\n" ;; *) return 1 ;; esac; }
    content="$(sed "s/^name: .*/name: Locally renamed/" "$1/standards/workflows/dev-lead.yml")"
    is_pin_compliant "$content" "$1/standards/workflows/dev-lead.yml" markets && echo compliant || echo drift
    content="$(ring_repin_uses dev-lead dev-lead/v1-stable < "$1/standards/workflows/dev-lead.yml")"
    is_pin_compliant "$content" "$1/standards/workflows/dev-lead.yml" markets && echo compliant || echo drift
  ' _ "$REPO_ROOT"
  echo "$output"
  [ "${lines[0]}" = compliant ]
  [ "${lines[1]}" = drift ]
}

@test "a lone CR inside a line is content, not a line ending (drift)" {
  sed 's/timeout-minutes: 5/timeout-minutes:\r 5/' "$TEMPLATE" > "$TT_TMP/stub.yml"
  assert_agree "$TT_TMP/stub.yml" drift
}
