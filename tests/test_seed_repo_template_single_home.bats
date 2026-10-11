#!/usr/bin/env bats
# Guard: this repo carries no `seed-repo-template.sh`
# (petry-projects/.github-private#1927).
#
# The seeder that writes the baseline scaffold into petry-projects/repo-template
# lives in petry-projects/.github-private, the one home of that name. This repo
# once had a different, smaller script under the same name. It only printed a
# standard file, yet the two were read as diverged copies of one tool and nothing
# said which was authoritative. That script is now scripts/emit-standard-file.sh.
# This guard keeps a second `seed-repo-template.sh` from reappearing here.

setup() {
  REPO_ROOT="$(cd -- "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  : "${SINGLE_HOME_ROOT:=$REPO_ROOT}"
}

# seed_copies — every tracked or untracked-but-not-ignored file named
# seed-repo-template.sh under the repo, one path per line.
seed_copies() {
  git -C "$SINGLE_HOME_ROOT" ls-files --cached --others --exclude-standard \
    | grep -E '(^|/)seed-repo-template\.sh$' || true
}

@test "no seed-repo-template.sh exists in this repo — its one home is petry-projects/.github-private" {
  run seed_copies
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "Found a seed-repo-template.sh in petry-projects/.github:"
    echo "$output"
    echo "The seeder's one home is petry-projects/.github-private/scripts/seed-repo-template.sh."
    echo "Change it there. To print a standard file from this repo, use scripts/emit-standard-file.sh."
    return 1
  fi
}

@test "the guard finds a copy when one is added, at any depth" {
  SINGLE_HOME_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SINGLE_HOME_ROOT/scripts" "$SINGLE_HOME_ROOT/tools/nested"
  git -C "$SINGLE_HOME_ROOT" init -q
  : > "$SINGLE_HOME_ROOT/scripts/emit-standard-file.sh"
  : > "$SINGLE_HOME_ROOT/scripts/not-seed-repo-template.sh"
  run seed_copies
  [ -z "$output" ]
  : > "$SINGLE_HOME_ROOT/scripts/seed-repo-template.sh"
  : > "$SINGLE_HOME_ROOT/tools/nested/seed-repo-template.sh"
  run seed_copies
  [ "$output" = "$(printf 'scripts/seed-repo-template.sh\ntools/nested/seed-repo-template.sh')" ]
}

@test "the emitter exists under its own name and says where the seeder lives" {
  [ -f "$REPO_ROOT/scripts/emit-standard-file.sh" ]
  grep -q 'petry-projects/.github-private' "$REPO_ROOT/scripts/emit-standard-file.sh"
}
