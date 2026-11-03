#!/usr/bin/env bats
# Tests for lib/trusted-authors.sh: whose text may reach the analyst.

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/trusted-authors.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

@test "check: admin and write are trusted" {
  for perm in admin write; do
    GH_STUB_STDOUT="$perm" run trusted_author_check "o/r" "alice"
    [ "$status" -eq 0 ]
  done
}

@test "check: read and none are not trusted" {
  for perm in read none; do
    GH_STUB_STDOUT="$perm" run trusted_author_check "o/r" "mallory"
    [ "$status" -eq 1 ]
  done
}

@test "check: an empty permission is not trusted" {
  GH_STUB_STDOUT="" run trusted_author_check "o/r" "mallory"
  [ "$status" -eq 1 ]
}

@test "check: an account the API cannot find is not trusted" {
  GH_STUB_STDERR="gh: Not Found (HTTP 404)" GH_STUB_EXIT=1 run trusted_author_check "o/r" "ghost"
  [ "$status" -eq 1 ]
}

@test "check: any other API failure is an error, not a verdict" {
  GH_STUB_STDERR="gh: Resource not accessible by integration (HTTP 403)" GH_STUB_EXIT=1 run trusted_author_check "o/r" "alice"
  [ "$status" -eq 2 ]
  [[ "$output" == *"permission lookup failed"* ]]
}

@test "check: the pipeline's own bot is trusted without an API call, in every spelling" {
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  for login in github-actions 'github-actions[bot]' app/github-actions; do
    run trusted_author_check "o/r" "$login"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$GH_STUB_LOG" ]
}

@test "check: other bots and path-shaped names are refused without an API call" {
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  export GH_STUB_STDOUT="admin"
  for login in 'dependabot[bot]' app/renovate '../../orgs/x' 'a b' '-x' ''; do
    run trusted_author_check "o/r" "$login"
    [ "$status" -eq 1 ]
  done
  [ ! -s "$GH_STUB_LOG" ]
}

@test "allowlist: returns only the trusted logins, as JSON" {
  script="${TT_TMP}/gh-script.tsv"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/permission-write.txt" >"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/permission-read.txt" >>"$script"
  export GH_STUB_SCRIPT="$script"
  result=$(printf 'alice\nmallory\n' | trusted_authors_allowlist "o/r")
  [ "$result" = '["alice"]' ]
}

@test "allowlist: fails on an API failure rather than returning a shorter list" {
  export GH_STUB_STDERR="HTTP 500" GH_STUB_EXIT=1
  run bash -c '. "$1"; printf "alice\n" | trusted_authors_allowlist "o/r"' _ "${TT_SCRIPTS_DIR}/lib/trusted-authors.sh"
  [ "$status" -eq 2 ]
}
