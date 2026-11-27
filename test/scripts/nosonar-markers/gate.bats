#!/usr/bin/env bats
# Tests for scripts/check-nosonar-markers.sh (#1613), the PR-time NOSONAR gate.
# Diff mode must only fail on markers a change ADDS, so existing markers never
# block an unrelated PR; tree mode checks everything.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
GATE="$REPO_ROOT/scripts/check-nosonar-markers.sh"

setup() {
  WORK="$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")"
  cd "$WORK"
  git init -q
  git config user.email t@example.invalid
  git config user.name t
  mkdir -p .github/workflows
  printf 'jobs:\n  x:\n    secrets: inherit  # NOSONAR\n' > .github/workflows/old.yml
  printf 'sonar.projectKey=x\nsonar.issue.ignore.multicriteria=a\n' > sonar-project.properties
  git add -A && git commit -qm base
  BASE=$(git rev-parse HEAD)
  unset GITHUB_ACTIONS
}

commit() { git add -A && git commit -qm change; }

@test "diff mode ignores a pre-existing bad marker" {
  printf 'print(1)\n' > a.py && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOSONAR markers OK"* ]]
}

@test "diff mode fails on an added bare marker and names the line" {
  printf 'x = 1\ny = 2  # NOSONAR\n' > a.py && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.py:2: error: bare NOSONAR"* ]]
}

@test "diff mode fails on an added Python key with a prefix" {
  printf 'y = 2  # NOSONAR(python:S117) legacy\n' > a.py && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Python rule keys are bare IDs"* ]]
}

@test "diff mode passes an added valid marker" {
  printf 'y = 2  # NOSONAR(S117) generated name\n' > a.py && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 0 ]
}

@test "diff mode flags a bad marker added to an existing file, not the old one" {
  printf '    env: {}  # NOSONAR(githubactions:S1)\n' >> .github/workflows/old.yml && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old.yml:4: error: NOSONAR(githubactions:S1) needs a reason"* ]]
  [[ "$output" != *"old.yml:3:"* ]]
}

@test "diff mode fails on an added sonar.issue.ignore key only" {
  printf 'sonar.issue.ignore.multicriteria.a.ruleKey=x:S1\n' >> sonar-project.properties && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sonar-project.properties:3: error: sonar.issue.ignore.multicriteria.a.ruleKey"* ]]
  [[ "$output" != *"sonar-project.properties:2:"* ]]
}

@test "diff mode emits GitHub annotations under Actions" {
  printf 'y = 2  # NOSONAR\n' > a.py && commit
  GITHUB_ACTIONS=true run bash "$GATE" --base "$BASE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=a.py,line=1::bare NOSONAR"* ]]
}

@test "diff mode skips node_modules" {
  mkdir -p node_modules/x && printf 'a()  // NOSONAR\n' > node_modules/x/i.js && commit
  run bash "$GATE" --base "$BASE"
  [ "$status" -eq 0 ]
}

@test "an unknown base ref is an error, not a pass" {
  run bash "$GATE" --base does-not-exist
  [ "$status" -eq 2 ]
}

@test "tree mode fails on the existing bad marker and only warns on properties" {
  run bash "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"old.yml:3: error: bare NOSONAR"* ]]
  [[ "$output" == *"sonar-project.properties:2: warning:"* ]]
}

@test "this repository's own tree has no invalid markers" {
  cd "$REPO_ROOT"
  run bash "$GATE"
  [ "$status" -eq 0 ]
}
