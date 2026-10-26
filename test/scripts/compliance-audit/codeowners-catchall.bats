#!/usr/bin/env bats
# Tests for the `codeowners-no-catchall` advisory in
# scripts/compliance-audit.sh (check_codeowners).
#
# A CODEOWNERS file should carry a default `*` catch-all so files not matched by
# any path-specific rule still have an owner — otherwise `require_code_owner_review`
# silently does not apply to them. The audit raises a `settings` /
# `codeowners-no-catchall` warning when no owner line uses `*` as its pattern.
# This suite locks in that detection and confirms the repo's own CODEOWNERS
# complies (the fix for issue #371).

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Mirrors the catch-all detection in check_codeowners
# (scripts/compliance-audit.sh): strip comment/blank lines, then look for an
# owner line whose pattern (first field) is exactly `*`.
# Returns 0 when a catch-all is present, 1 when it is absent.
# ---------------------------------------------------------------------------
_has_catchall() {
  local content="$1" owner_lines
  owner_lines=$(printf '%s\n' "$content" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
  printf '%s\n' "$owner_lines" | awk '{print $1}' | grep -qxF '*'
}

# Repo root, derived from this test file's location (test/scripts/compliance-audit).
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Catch-all present → no finding
# ---------------------------------------------------------------------------

@test "a sole catch-all line is detected" {
  run _has_catchall '* @combsmith/org-leads'
  [ "$status" -eq 0 ]
}

@test "a catch-all alongside path-specific rules is detected" {
  body=$'* @combsmith/org-leads\n/security/ @combsmith/org-leads @combsmith/security-leads'
  run _has_catchall "$body"
  [ "$status" -eq 0 ]
}

@test "comments and blank lines around the catch-all do not hide it" {
  body=$'# CODEOWNERS\n\n# Default catch-all\n* @combsmith/org-leads\n'
  run _has_catchall "$body"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Catch-all absent → finding (status 1)
# ---------------------------------------------------------------------------

@test "only path-specific rules (no catch-all) is reported" {
  body=$'/docs/ @combsmith/org-leads\n/security/ @combsmith/org-leads @combsmith/security-leads'
  run _has_catchall "$body"
  [ "$status" -eq 1 ]
}

@test "a commented-out catch-all does not count" {
  body=$'# * @combsmith/org-leads\n/docs/ @combsmith/org-leads'
  run _has_catchall "$body"
  [ "$status" -eq 1 ]
}

@test "a pattern merely containing '*' (not equal to it) does not count" {
  run _has_catchall '*.md @combsmith/org-leads'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The repo's own CODEOWNERS complies (issue #371)
# ---------------------------------------------------------------------------

@test "the repository CODEOWNERS file has a catch-all" {
  [ -f "$REPO_ROOT/.github/CODEOWNERS" ]
  run _has_catchall "$(cat "$REPO_ROOT/.github/CODEOWNERS")"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# End-to-end check_codeowners validation (precedence, inline comments,
# catch-all extra owners, non-org/bare owner tokens)
# ---------------------------------------------------------------------------

_run_codeowners_body() {
  local body="$1"
  local tmp
  tmp="$(mktemp -d "$BATS_TEST_TMPDIR/co.XXXXXX")"
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
  chmod +x "$tmp/bin/sleep"
  local b64
  b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
  cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
printf '{"content":"%s"}\n' "$b64"
EOF
  chmod +x "$tmp/bin/gh"
  PATH="$tmp/bin:$PATH" REPORT_DIR="$tmp" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_codeowners "demo-repo"
    cat "$REPORT_DIR/findings.json"
  '
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

@test "check_codeowners: inline '#' comments on catch-all and path rules are ignored" {
  body=$'* @combsmith/org-leads # default owner (not @individual)\n/security/ @combsmith/org-leads @combsmith/security-leads # cc @someone\n'
  run _run_codeowners_body "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "check_codeowners: catch-all '*' with extra team is flagged (codeowners-catchall-extra-owners)" {
  body=$'* @combsmith/org-leads @combsmith/other-team\n'
  run _run_codeowners_body "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeowners-catchall-extra-owners"* ]]
  [[ "$output" == *"error"* ]]
}

@test "check_codeowners: non-org team, bare username, or malformed team slug is flagged (codeowners-individual-users)" {
  body=$'* @combsmith/org-leads\n/docs/ @combsmith/org-leads @other-org/team bareuser @combsmith/Org_Leads.With.Dots\n'
  run _run_codeowners_body "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeowners-individual-users"* ]]
  [[ "$output" == *"@other-org/team"* ]]
  [[ "$output" == *"bareuser"* ]]
  [[ "$output" == *"@combsmith/Org_Leads.With.Dots"* ]]
}

@test "check_codeowners: CRLF line endings do not trigger false positives" {
  body=$'* @combsmith/org-leads\r\n/docs/ @combsmith/org-leads @combsmith/doc-leads\r\n'
  run _run_codeowners_body "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "check_codeowners: escaped-space path patterns do not mis-tokenize owners" {
  body=$'* @combsmith/org-leads\nmy\\ dir/ @combsmith/org-leads\npath/with\\ multiple\\ spaces/ @combsmith/org-leads @combsmith/platform-leads\n'
  run _run_codeowners_body "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "check_codeowners: probes .github/CODEOWNERS before root CODEOWNERS (GitHub precedence)" {
  local tmp
  tmp="$(mktemp -d "$BATS_TEST_TMPDIR/co-prec.XXXXXX")"
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
  chmod +x "$tmp/bin/sleep"
  local good_b64 bad_b64
  good_b64="$(printf '* @combsmith/org-leads\n' | base64 | tr -d '\n')"
  bad_b64="$(printf '* @individual\n' | base64 | tr -d '\n')"
  cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"contents/.github/CODEOWNERS"*) printf '{"content":"%s"}\n' "$good_b64" ;;
  *"contents/CODEOWNERS"*)         printf '{"content":"%s"}\n' "$bad_b64" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
EOF
  chmod +x "$tmp/bin/gh"
  run env PATH="$tmp/bin:$PATH" REPORT_DIR="$tmp" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_codeowners "demo-repo"
    cat "$REPORT_DIR/findings.json"
  '
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
