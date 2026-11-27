#!/usr/bin/env bats
# Tests for nosonar_scan_content() in scripts/lib/nosonar-markers.sh — the shared
# NOSONAR marker rule behind the PR-time gate and the compliance audit (#1613).

bats_require_minimum_version 1.5.0

LIB="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/lib/nosonar-markers.sh"

scan() { # <path> <content>
  run bash -c '. "$1"; nosonar_scan_content "$2" "$3"' _ "$LIB" "$1" "$2"
  [ "$status" -eq 0 ]
}

@test "valid YAML marker passes" {
  scan wf.yml '    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable'
  [ -z "$output" ]
}

@test "valid Python marker passes" {
  scan a.py 'subprocess.run(cmd, shell=False)  # NOSONAR(S4721) cmd is a fixed argv list'
  [ -z "$output" ]
}

@test "Python marker with several bare rule IDs passes" {
  scan a.py 'x = 1  # NOSONAR(S117, S1481) generated name kept for parity'
  [ -z "$output" ]
}

@test "bare NOSONAR in YAML is flagged" {
  scan wf.yml '    secrets: inherit  # NOSONAR'
  [[ "$output" == "wf.yml:1: bare NOSONAR"* ]]
}

@test "bare NOSONAR in Python is flagged" {
  scan a.py 'x = 1  # NOSONAR'
  [[ "$output" == "a.py:1: bare NOSONAR"* ]]
}

@test "Python key with a python: prefix is flagged" {
  scan a.py 'x = 1  # NOSONAR(python:S117) legacy name'
  [[ "$output" == *"Python rule keys are bare IDs"* ]]
}

@test "Python key with a pythonsecurity: prefix is flagged" {
  scan a.py 'x = 1  # NOSONAR(pythonsecurity:S4721) fixed argv'
  [[ "$output" == *"Python rule keys are bare IDs"* ]]
}

@test "Python NOSONAR that does not open the comment is flagged" {
  scan a.py 'x = 1  # see NOSONAR(S117) docs'
  [[ "$output" == *"must open the comment in Python"* ]]
}

@test "YAML key without the analyzer prefix is flagged" {
  scan wf.yml '    secrets: inherit  # NOSONAR(S7635) first-party'
  [[ "$output" == *"YAML rule keys need the analyzer prefix"* ]]
}

@test "missing reason is flagged" {
  scan wf.yml '    secrets: inherit  # NOSONAR(githubactions:S7635)'
  [[ "$output" == *"needs a reason"* ]]
}

@test "missing reason is flagged in Python" {
  scan a.py 'x = 1  # NOSONAR(S117)'
  [[ "$output" == *"needs a reason"* ]]
}

@test "empty parentheses are flagged" {
  scan run.sh 'echo hi  # NOSONAR() why'
  [[ "$output" == *"name the rule"* ]]
}

@test "NOSONAR inside a shell string is not a marker" {
  scan run.sh "if grep -qF 'NOSONAR(githubactions:S7637)' f; then echo \"NOSONAR\"; fi"
  [ -z "$output" ]
}

@test "NOSONAR inside a Python string is not a marker" {
  scan a.py 'msg = "use # NOSONAR here"'
  [ -z "$output" ]
}

@test "NOSONAR inside a quoted YAML scalar is not a marker" {
  scan wf.yml "      run: echo '# NOSONAR'"
  [ -z "$output" ]
}

@test "an apostrophe in a plain YAML scalar does not hide a later comment" {
  scan wf.yml "  description: don't skip  # NOSONAR"
  [[ "$output" == *"bare NOSONAR"* ]]
}

@test "shell \$# is not a comment" {
  scan run.sh 'echo $# NOSONAR'
  [ -z "$output" ]
}

@test "prose comment quoting a valid marker passes" {
  scan wf.yml '# Each uses: line carries the inline `# NOSONAR(githubactions:S7637)` marker: the ref is a'
  [ -z "$output" ]
}

@test "valid C-style line comment passes" {
  scan a.ts 'const x = eval(s); // NOSONAR(typescript:S1523) trusted build-time input'
  [ -z "$output" ]
}

@test "bare NOSONAR in a C-style block comment is flagged" {
  scan a.js 'foo(); /* NOSONAR */'
  [[ "$output" == *"bare NOSONAR"* ]]
}

@test "valid C-style block comment passes" {
  scan a.js 'foo(); /* NOSONAR(S1234) reason here */ bar();'
  [ -z "$output" ]
}

@test "multi-line block comment reports the right line" {
  scan a.js "$(printf 'a();\n/*\n * NOSONAR\n */\nb();\n')"
  [ "$output" = "a.js:3: bare NOSONAR: name the rule, e.g. NOSONAR(S1234) <reason>" ]
}

@test "files of unscanned types are ignored" {
  scan README.md 'Use `# NOSONAR` sparingly.'
  [ -z "$output" ]
}

@test "line numbers point at the marker line" {
  scan wf.yml "$(printf 'on: push\njobs:\n  x:\n    secrets: inherit  # NOSONAR\n')"
  [[ "$output" == "wf.yml:4: "* ]]
}

@test "nosonar_issue_ignore_lines lists keys and skips comments" {
  run bash -c '. "$1"; nosonar_issue_ignore_lines "$2"' _ "$LIB" \
    "$(printf 'sonar.projectKey=x\n# sonar.issue.ignore.multicriteria=no\nsonar.issue.ignore.multicriteria=a\nsonar.issue.ignore.multicriteria.a.ruleKey=x:S1\n')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3: sonar.issue.ignore.multicriteria" ]
  [ "${lines[1]}" = "4: sonar.issue.ignore.multicriteria.a.ruleKey" ]
  [ "${#lines[@]}" -eq 2 ]
}
