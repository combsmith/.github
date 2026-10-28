#!/usr/bin/env bats
# Tests for remediate_unpinned_actions in scripts/compliance-remediate.sh
# (issue #1397).
#
# The action references being pinned are read from the TARGET repository's
# workflow file, so they are untrusted data. They used to be spliced into a sed
# program (`s|uses:…ref|uses: action@sha # tag|g`), where sed metacharacters in
# the ref (`&`, `|`, `\`, …) changed what the program did. The fixed contract:
#
#   - each ref must match a strict owner/repo[/path]@ref allowlist before it is
#     looked up or patched; a ref outside it is left untouched and reported;
#   - the patch is a literal string replacement, never a sed/regex program;
#   - ordinary refs (actions and reusable-workflow paths) are still pinned.
#
# The gh stub scripts the fetch → resolve → branch → PUT → PR flow and saves the
# base64 content of the PUT so the patched workflow can be compared byte-for-byte.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

SHA_A="1111111111111111111111111111111111111111"

install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
sub="${1:-}"; shift || true
case "$sub" in
  pr)
    case "${1:-}" in
      list)   : ;;
      create) echo "https://github.com/combsmith/demo/pull/9" ;;
    esac ;;
  label) exit 0 ;;
  api)
    method="GET"
    if [ "${1:-}" = "-X" ]; then method="$2"; shift 2; fi
    endpoint="${1:-}"
    case "$method $endpoint" in
      "PUT "*contents/.github/workflows/*)
        for a in "$@"; do
          case "$a" in content=*) printf '%s' "${a#content=}" > "$GH_PUT_CONTENT" ;; esac
        done ;;
      "POST "*/git/refs) exit 0 ;;
      "GET "*contents/.github/workflows/*)
        printf '{"sha":"filesha","content":"%s"}' "$GH_WF_B64" ;;
      "GET "*/git/refs/tags/*)
        printf '{"object":{"type":"commit","sha":"%s"}}' "$GH_TAG_SHA" ;;
      "GET "*/git/refs/heads/*)
        case "$*" in
          *object.sha*) echo "basesha111" ;;
          *) exit 1 ;;  # sync branch does not exist yet
        esac ;;
      "GET repos/"*) echo "main" ;;
    esac ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"
  export PATH
}

b64() { base64 | tr -d '\n'; }
b64d() { base64 -d 2>/dev/null || base64 -D; }

setup() {
  tt_make_tmpdir
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  GH_PUT_CONTENT="${TT_TMP}/put-content.b64"; export GH_PUT_CONTENT
  GH_TAG_SHA="$SHA_A"; export GH_TAG_SHA
  : > "$GH_CALLS"
  install_gh_stub
}

teardown() {
  tt_cleanup_tmpdir
}

# run_pin <workflow-text> : remediate one unpinned-actions finding for ci.yml
run_pin() {
  GH_WF_B64="$(printf '%s' "$1" | b64)"; export GH_WF_B64
  local findings
  findings="$(tt_write_finding "demo" "action-pinning" "unpinned-actions-ci.yml")"
  GH_TOKEN=fake \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="${TT_TMP}/report" \
    DRY_RUN=false \
    run bash "$TT_SCRIPT"
}

put_content() { b64d < "$GH_PUT_CONTENT"; }

@test "pins ordinary action and reusable-workflow refs literally" {
  wf=$'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n      - uses:   my.org/set-up.tool@v1.2.3\n  b:\n    uses: other-org/repo/.github/workflows/build.yml@release/v2\n'
  run_pin "$wf"
  [ "$status" -eq 0 ]

  expected=$'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@'"$SHA_A"$' # v4\n      - uses: my.org/set-up.tool@'"$SHA_A"$' # v1.2.3\n  b:\n    uses: other-org/repo/.github/workflows/build.yml@'"$SHA_A"$' # release/v2'
  [ "$(put_content)" = "$expected" ]
}

@test "#1397: a ref with sed replacement metacharacters is rejected, not spliced into the patch" {
  # `&` in a sed replacement re-inserts the whole match; `|` ends the s command
  # and lets the rest of the tag act as sed flags/commands.
  wf=$'steps:\n  - uses: actions/checkout@v4\n  - uses: evil/act@v1&x\n  - uses: evil/act2@v1|e;s|x|y\n'
  run_pin "$wf"

  # The crafted refs never reach the GitHub API …
  ! grep -qF 'v1&x' "$GH_CALLS"
  ! grep -qF 'v1|e' "$GH_CALLS"
  # … and are left byte-for-byte unchanged, while the valid ref is still pinned.
  expected=$'steps:\n  - uses: actions/checkout@'"$SHA_A"$' # v4\n  - uses: evil/act@v1&x\n  - uses: evil/act2@v1|e;s|x|y'
  [ "$(put_content)" = "$expected" ]

  # The skipped refs are surfaced as partial failure in the PR/commit text.
  grep -q '2 action(s) could not be resolved' "$GH_CALLS"
}

@test "#1397: a ref with a backslash or a dot-dot path segment is rejected" {
  wf=$'steps:\n  - uses: evil/act@v1\\\\1\n  - uses: evil/..@v1\n'
  run_pin "$wf"

  ! grep -qF 'repos/evil/act/' "$GH_CALLS"
  ! grep -qF 'repos/evil/..' "$GH_CALLS"
  # Nothing was pinnable, so nothing is pushed.
  [ ! -e "$GH_PUT_CONTENT" ]
  grep -q 'unpinned-actions-ci.yml' "${TT_TMP}/report/skipped.md"
}

@test "#1397: a non-SHA value from tag resolution is never written into the workflow" {
  GH_TAG_SHA='abc|e' ; export GH_TAG_SHA
  wf=$'steps:\n  - uses: actions/checkout@v4\n'
  run_pin "$wf"

  [ ! -e "$GH_PUT_CONTENT" ]
  grep -q 'unpinned-actions-ci.yml' "${TT_TMP}/report/skipped.md"
}
