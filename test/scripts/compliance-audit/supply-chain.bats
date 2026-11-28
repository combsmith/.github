#!/usr/bin/env bats
# Tests for the supply-chain compliance check in scripts/compliance-audit.sh
# (issue #1618, standards/supply-chain.md):
#
#   supply_chain_publishes_artifacts <workflows> — is this repo in scope?
#   supply_chain_missing_controls    <workflows> — which controls are absent?
#   supply_chain_exempt_controls     <file> <repo> — which controls are exempted?
#   check_supply_chain               <repo>      — warn-mode findings end to end
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real helpers are exercised directly.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/compliance-audit.sh"
EXEMPTIONS="$REPO_ROOT/standards/workflow-exemptions.json"

publishes() {
  run bash -c 'source "$1" >/dev/null 2>&1; supply_chain_publishes_artifacts "$2"' \
    _ "$SCRIPT" "$1"
}

missing() {
  run bash -c 'source "$1" >/dev/null 2>&1; supply_chain_missing_controls "$2"' \
    _ "$SCRIPT" "$1"
}

exempt() {
  run bash -c 'source "$1" >/dev/null 2>&1; supply_chain_exempt_controls "$2" "$3"' \
    _ "$SCRIPT" "$1" "$2"
}

setup() {
  TT_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TT_TMP"
}

# ---------------------------------------------------------------------------
# Scope: which repos publish artifacts
# ---------------------------------------------------------------------------

@test "publishes: a release-triggered workflow is in scope" {
  publishes "$(printf 'name: Release\non:\n  release:\n    types: [published]\njobs:\n  build:\n    runs-on: ubuntu-latest\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: an inline 'on: release' trigger is in scope" {
  publishes "$(printf 'on: [push, release]\njobs:\n  b:\n    runs-on: ubuntu-latest\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: a gh-release action is in scope" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      - uses: softprops/action-gh-release@abc # v2\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: docker build-push is in scope" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      - uses: docker/build-push-action@abc # v6\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: npm publish in a run step is in scope" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      - run: npm publish --provenance\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: gh release create is in scope" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      - run: gh release create v1.0.0 dist/*\n')"
  [ "$status" -eq 0 ]
}

@test "publishes: gh release download is NOT in scope (consumes, does not publish)" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      - run: gh release download v8.30.1 --repo gitleaks/gitleaks\n')"
  [ "$status" -eq 1 ]
}

@test "publishes: a publish signal only inside a comment is NOT in scope" {
  publishes "$(printf 'jobs:\n  r:\n    steps:\n      # - run: npm publish\n      #   uses: softprops/action-gh-release@abc\n      - run: echo hi\n')"
  [ "$status" -eq 1 ]
}

@test "publishes: a plain CI workflow is NOT in scope" {
  publishes "$(cat "$REPO_ROOT/standards/workflows/ci.yml")"
  [ "$status" -eq 1 ]
}

@test "publishes: empty input is NOT in scope" {
  publishes ""
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Missing controls
# ---------------------------------------------------------------------------

@test "missing: a workflow with no controls reports all three" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: npm publish\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nsbom\nprovenance')" ]
}

@test "missing: the canonical templates together satisfy every control" {
  missing "$(cat "$REPO_ROOT/standards/workflows/ci.yml" "$REPO_ROOT/standards/workflows/release-attest.yml")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing: ci.yml alone still lacks sbom and provenance" {
  missing "$(cat "$REPO_ROOT/standards/workflows/ci.yml")"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'sbom\nprovenance')" ]
}

@test "missing: CycloneDX and SLSA generator alternatives are accepted" {
  missing "$(printf 'on: [pull_request]\njobs:\n  a:\n    steps:\n      - uses: actions/dependency-review-action@abc\n      - uses: CycloneDX/gh-node-module-generatebom@abc\n  b:\n    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2\n')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing: controls named only in comments do not count" {
  missing "$(printf 'jobs:\n  a:\n    steps:\n      # - uses: actions/dependency-review-action@abc\n      # - uses: anchore/sbom-action@abc\n      # - uses: actions/attest-build-provenance@abc\n      - run: echo hi\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nsbom\nprovenance')" ]
}

@test "missing: a step named 'syft' without run does not suppress sbom finding" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - name: syft\n        run: echo hello\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nsbom\nprovenance')" ]
}

@test "missing: syft at end of line in run step is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: syft\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nprovenance')" ]
}

@test "missing: cdxgen at end of line in run step is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: cdxgen\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nprovenance')" ]
}

@test "missing: syft in multiline run block is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: |\n          syft packages -o sbom.json\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nprovenance')" ]
}

@test "missing: publish with multiple spaces is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: npm    publish\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nsbom\nprovenance')" ]
}

@test "missing: publish with tab is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: npm\tpublish\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nsbom\nprovenance')" ]
}

@test "missing: cyclonedx-npm at end of line is detected" {
  missing "$(printf 'jobs:\n  r:\n    steps:\n      - run: cyclonedx-npm\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dependency-review\nprovenance')" ]
}

# ---------------------------------------------------------------------------
# Exemptions
# ---------------------------------------------------------------------------

@test "exemptions: the committed workflow-exemptions.json is valid and declares supply_chain_exemptions" {
  run jq -e '(.supply_chain_exemptions | type) == "array"' "$EXEMPTIONS"
  [ "$status" -eq 0 ]
  # Existing immutable_files contract is untouched.
  run jq -e '.immutable_files | length >= 1' "$EXEMPTIONS"
  [ "$status" -eq 0 ]
}

@test "exemptions: every committed entry has a repo, known controls and a reason" {
  run jq -e '[.supply_chain_exemptions[]
    | (.repo | type == "string" and length > 0)
      and (.reason | type == "string" and length > 0)
      and (.controls | type == "array" and length > 0
           and all(. == "dependency-review" or . == "sbom" or . == "provenance"))]
    | all' "$EXEMPTIONS"
  [ "$status" -eq 0 ]
}

@test "exemptions: listed controls are returned for the matching repo only" {
  cat > "$TT_TMP/ex.json" <<'JSON'
{"immutable_files": [], "supply_chain_exemptions": [
  {"repo": "foo", "controls": ["sbom", "provenance"], "reason": "publishes nothing consumable"},
  {"repo": "bar", "controls": ["dependency-review"], "reason": "no dependency graph"}
]}
JSON
  exempt "$TT_TMP/ex.json" foo
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'sbom\nprovenance')" ]
  exempt "$TT_TMP/ex.json" baz
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exemptions: an entry without a reason is not honoured" {
  cat > "$TT_TMP/ex.json" <<'JSON'
{"supply_chain_exemptions": [{"repo": "foo", "controls": ["sbom"], "reason": ""}]}
JSON
  exempt "$TT_TMP/ex.json" foo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exemptions: object-valued supply_chain_exemptions or controls fail closed" {
  echo '{"supply_chain_exemptions": {"repo": "foo", "controls": ["sbom"], "reason": "r"}}' > "$TT_TMP/ex1.json"
  exempt "$TT_TMP/ex1.json" foo
  [ -z "$output" ]
  echo '{"supply_chain_exemptions": [{"repo": "foo", "controls": {"a": "sbom"}, "reason": "r"}]}' > "$TT_TMP/ex2.json"
  exempt "$TT_TMP/ex2.json" foo
  [ -z "$output" ]
}

@test "exemptions: a malformed file yields no exemptions" {
  echo '{not json' > "$TT_TMP/bad.json"
  exempt "$TT_TMP/bad.json" foo
  [ "$status" -eq 0 ]
  [[ "$output" != *sbom* ]]
}

@test "exemptions: a missing or unreadable file yields no exemptions" {
  exempt "$TT_TMP/does-not-exist.json" foo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# check_supply_chain end to end (gh stubbed via list_workflow_files / gh_api)
# ---------------------------------------------------------------------------

# run_check <exemptions-file> <wf-name>=<file> ... — run check_supply_chain on
# repo "demo" with the given workflow files served by the stubs; prints the
# findings JSON.
run_check() {
  local ex="$1"; shift
  local spec
  : > "$TT_TMP/names"
  for spec in "$@"; do
    printf '%s\n' "${spec%%=*}" >> "$TT_TMP/names"
    cp "${spec#*=}" "$TT_TMP/wf-${spec%%=*}"
  done
  run bash -c '
    source "$1" >/dev/null 2>&1
    T="$2"
    REPORT_DIR="$T"; FINDINGS_FILE="$T/findings.json"; echo "[]" > "$FINDINGS_FILE"
    SUPPLY_CHAIN_EXEMPTIONS_FILE="$3"
    list_workflow_files() { cat "$T/names"; }
    gh_api() {
      local path="$1" name
      name="${path##*/}"
      [ -f "$T/wf-$name" ] || return 1
      base64 -w0 < "$T/wf-$name"; echo
    }
    check_supply_chain demo 2>/dev/null
    cat "$FINDINGS_FILE"
  ' _ "$SCRIPT" "$TT_TMP" "$ex"
}

@test "check: a non-publishing repo raises no findings" {
  run_check "$EXEMPTIONS" "ci.yml=$REPO_ROOT/standards/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "check: a publishing repo missing every control raises three warning findings" {
  printf 'on:\n  release:\n    types: [published]\njobs:\n  r:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm publish\n' > "$TT_TMP/release.yml"
  run_check "$EXEMPTIONS" "release.yml=$TT_TMP/release.yml"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 3 ]
  [ "$(echo "$output" | jq -r '[.[].severity] | unique | join(",")')" = "warning" ]
  [ "$(echo "$output" | jq -r '[.[].category] | unique | join(",")')" = "supply-chain" ]
  [ "$(echo "$output" | jq -r '[.[].check] | sort | join(",")')" = "supply-chain-missing-dependency-review,supply-chain-missing-provenance,supply-chain-missing-sbom" ]
  [ "$(echo "$output" | jq -r '[.[].standard_ref] | unique | .[0]')" = "standards/supply-chain.md" ]
}

@test "check: a publishing repo with the canonical templates is compliant" {
  run_check "$EXEMPTIONS" \
    "ci.yml=$REPO_ROOT/standards/workflows/ci.yml" \
    "release-attest.yml=$REPO_ROOT/standards/workflows/release-attest.yml"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "check: exempted controls are not reported" {
  printf 'on:\n  release:\njobs:\n  r:\n    steps:\n      - run: npm publish\n' > "$TT_TMP/release.yml"
  printf '{"supply_chain_exemptions":[{"repo":"demo","controls":["sbom","provenance"],"reason":"test"}]}\n' > "$TT_TMP/ex.json"
  run_check "$TT_TMP/ex.json" "release.yml=$TT_TMP/release.yml"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].check] | join(",")')" = "supply-chain-missing-dependency-review" ]
}

@test "check: is wired into the per-repo audit loop" {
  run grep -qE '^[[:space:]]+check_supply_chain "\$repo"$' "$SCRIPT"
  [ "$status" -eq 0 ]
}
