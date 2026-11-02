#!/usr/bin/env bats
# combsmith/.github#1396: the auto-rebase reusable publishes manual recovery
# commands (`git rebase origin/<base>` / `git merge origin/<base>`) in PR
# comments. A git branch name may legally contain shell syntax ($, `, ;, |, &,
# parentheses, quotes), so the base branch must be shell-quoted before it is
# pasted into a command a maintainer will copy and run.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/auto-rebase-reusable.yml"

setup() {
  tt_make_tmpdir
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/comments.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

@test "shell_quote: ordinary ref names are emitted unchanged (readable comment)" {
  run auto_rebase_shell_quote "origin/main"
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
  run auto_rebase_shell_quote "origin/release/v1.2_x-y+z"
  [ "$output" = "origin/release/v1.2_x-y+z" ]
}

@test "shell_quote: hostile but git-valid branch names round-trip as ONE literal word and never execute" {
  local marker="${TT_TMP}/pwned" v quoted
  local -a cases=(
    "origin/x;touch\${IFS}${marker}"
    "origin/x\$(touch\${IFS}${marker})"
    "origin/x\`touch\${IFS}${marker}\`"
    "origin/x|touch\${IFS}${marker}"
    "origin/x&&touch\${IFS}${marker}"
    "origin/it's'\"quoted\""
    "origin/a'b'c"
  )
  for v in "${cases[@]}"; do
    # Precondition: git itself accepts the branch name.
    git check-ref-format --branch "${v#origin/}" >/dev/null
    quoted=$(auto_rebase_shell_quote "$v")
    # What a maintainer's shell sees when running `git rebase <quoted>`:
    eval "set -- ${quoted}"
    [ "$#" -eq 1 ] || { echo "split into $# words: $quoted"; return 1; }
    [ "$1" = "$v" ] || { echo "round-trip mismatch: $quoted -> $1"; return 1; }
  done
  [ ! -e "$marker" ]
}

@test "shell_quote: also safe under a POSIX sh (the maintainer's shell may not be bash)" {
  local marker="${TT_TMP}/pwned-sh" v="origin/x'\$(touch ${marker})'" quoted
  quoted=$(auto_rebase_shell_quote "$v")
  run sh -c "printf '%s' ${quoted}"
  [ "$status" -eq 0 ]
  [ "$output" = "$v" ]
  [ ! -e "$marker" ]
}

@test "reusable: manual recovery commands use the shell-quoted base ref, never raw \$BASE_BRANCH" {
  # The raw interpolation that #1396 reported must be gone ...
  run grep -nE 'git (rebase|merge) origin/\$\{?BASE_BRANCH' "$REUSABLE"
  [ "$status" -eq 1 ]
  # ... replaced by the helper-quoted argument in both comment bodies.
  run grep -cE 'git (rebase|merge) \$\{?MANUAL_BASE_REF\}?' "$REUSABLE"
  [ "$output" -eq 2 ]
  run grep -E 'MANUAL_BASE_REF=\$\(auto_rebase_shell_quote "origin/\$\{?BASE_BRANCH\}?"\)' "$REUSABLE"
  [ "$status" -eq 0 ]
}
