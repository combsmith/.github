#!/usr/bin/env bats
# Regression guard for the secret-scan job's gitleaks config in
# .github/workflows/ci.yml.
#
# Pins issue #996: ci.yml's `Run gitleaks` step invoked `gitleaks detect` WITHOUT
# `--config .gitleaks.toml`, so gitleaks fell back to its default ruleset. The
# default `generic-api-key` rule fires false positives on certain file
# paths/names (see standards/push-protection.md — "Why a required config file?"),
# so a run whose commit range touched such a file failed while others passed —
# the content-dependent, intermittent failure behind the fleet failure-rate
# warning (11.1% = 1/9 runs). The canonical Layer-3 spec
# (standards/push-protection.md:241, 257-258) requires `--config .gitleaks.toml`
# and every adopting repo MUST ship that file at root. These tests assert both,
# so a future edit can't silently drop the config and reintroduce the flakiness.
#
# Pins issue #1395: a config passed via --config REPLACES gitleaks' built-in
# ruleset. The allowlist-only .gitleaks.toml / standards/gitleaks.toml had no
# `[extend] useDefault = true`, so the scan ran with ZERO rules and passed on
# any history. The detection tests below run the pinned gitleaks binary (the
# same invocation as ci.yml's `Run gitleaks` step) against a throwaway repo
# holding synthetic credentials and assert each shipped config catches them.
# gitleaks MUST be on PATH — ci-tests.yml installs the version pinned in ci.yml.

load 'helpers/setup'

# Emit the `run:` step block whose text contains the given marker substring.
# Steps in ci.yml start at a 6-space "- " (the `steps:` child indent); every
# deeper-indented line belongs to that step.
step_block_with() {
  local marker="$1"
  local block="" out="" line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "      - "* ]]; then
      if [[ "$block" == "      - "* ]]; then
        [[ "$block" == *"$marker"* ]] && out="$block"
      fi
      block="$line"$'\n'
    else
      if [[ -n "$block" ]]; then
        block+="$line"$'\n'
      fi
    fi
  done < "$TT_WORKFLOW"
  if [[ "$block" == "      - "* ]]; then
    [[ "$block" == *"$marker"* ]] && out="$block"
  fi
  printf '%s' "$out"
}

@test "secret-scan: the ci workflow exists" {
  [[ -f "$TT_WORKFLOW" ]]
}

@test "secret-scan: gitleaks scan passes --config .gitleaks.toml" {
  # The config extends gitleaks' default ruleset and adds the allowlist that
  # suppresses generic-api-key false positives on certain filenames (#996).
  local block command
  block="$(step_block_with 'gitleaks detect')"
  [[ -n "$block" ]]
  # Extract the run: command from the step block
  command="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]*run:[[:space:]]*(.*)$/\1/p')"
  [[ "$command" == gitleaks\ detect* ]]
  [[ "$command" == *"--config .gitleaks.toml"* ]]
}

@test "secret-scan: the .gitleaks.toml config ships at repo root" {
  # The --config flag references a file that MUST exist at root, or the scan
  # fails with file-not-found (standards/push-protection.md#gitleakstoml-template).
  [[ -f "${TT_REPO_ROOT}/.gitleaks.toml" ]]
}

# --- Detection: the shipped configs must actually run gitleaks' rules (#1395) ---

TT_CI_TESTS_WORKFLOW="${TT_REPO_ROOT}/.github/workflows/ci-tests.yml"

# Fail (never skip — AGENTS.md) when the scanner is missing.
require_gitleaks() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks not on PATH — install the version pinned in .github/workflows/ci.yml" >&2
    return 1
  fi
}

# Build a throwaway git repo holding synthetic, obviously-fake credentials.
# Each value is assembled at runtime from split pieces so no secret-shaped
# literal is ever committed here (this repo's own secret scan stays clean).
make_secret_fixture() {
  local dir="$1"
  local aws="AK""IA""QZ7RT2MX""4KLP3WVN"
  local ghp="gh""p_""Zx9Kq2Lm8Np4Rt6V""w1Yb3Cd5Fg7Hj0Kl2Mn4P"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'aws_access_key_id = %s\ngithub_token = %s\n' "$aws" "$ghp" > "$dir/fake-creds.txt"
  git -C "$dir" add fake-creds.txt
  git -C "$dir" -c user.name=bats -c user.email=bats@example.invalid \
    -c commit.gpgsign=false commit -q -m "synthetic secret fixture"
}

# Scan the fixture's git history exactly as ci.yml's `Run gitleaks` step does,
# plus a JSON report so the test can assert which rules fired.
scan_fixture_with() {
  local config="$1"
  local fixture="${BATS_TEST_TMPDIR}/fixture"
  make_secret_fixture "$fixture"
  REPORT="${BATS_TEST_TMPDIR}/report.json"
  run gitleaks detect --source "$fixture" --config "$config" --redact --verbose \
    --exit-code 1 --report-format json --report-path "$REPORT"
}

# Print the value of `useDefault` inside the `[extend]` table of a gitleaks TOML.
extend_use_default() {
  awk '
    /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\][[:space:]]*(#.*)?$/); next }
    in_extend && /^[[:space:]]*useDefault[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); print; exit
    }
  ' "$1"
}

@test "secret-scan: .gitleaks.toml extends the gitleaks default ruleset" {
  [ "$(extend_use_default "${TT_REPO_ROOT}/.gitleaks.toml")" = "true" ]
}

@test "secret-scan: standards/gitleaks.toml template extends the gitleaks default ruleset" {
  [ "$(extend_use_default "${TT_REPO_ROOT}/standards/gitleaks.toml")" = "true" ]
}

@test "secret-scan: .gitleaks.toml detects a synthetic secret in git history" {
  require_gitleaks
  scan_fixture_with "${TT_REPO_ROOT}/.gitleaks.toml"
  [ "$status" -eq 1 ]
  grep -q '"RuleID": "aws-access-token"' "$REPORT"
  grep -q '"RuleID": "github-pat"' "$REPORT"
}

@test "secret-scan: standards/gitleaks.toml template detects a synthetic secret in git history" {
  require_gitleaks
  scan_fixture_with "${TT_REPO_ROOT}/standards/gitleaks.toml"
  [ "$status" -eq 1 ]
  grep -q '"RuleID": "aws-access-token"' "$REPORT"
  grep -q '"RuleID": "github-pat"' "$REPORT"
}

@test "secret-scan: control — an allowlist-only config (no [extend]) detects nothing" {
  # Documents the #1395 failure mode and proves the detection tests above can
  # tell a working config from a zero-rule one.
  require_gitleaks
  local cfg="${BATS_TEST_TMPDIR}/allowlist-only.toml"
  printf '[allowlist]\ndescription = "Allowlisted paths"\npaths = [\n  %s,\n]\n' "'''_bmad/'''" > "$cfg"
  scan_fixture_with "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no leaks found"* ]]
}

@test "secret-scan: ci-tests.yml installs the same pinned gitleaks release as ci.yml" {
  # The detection tests are only meaningful against the binary CI scans with.
  local want_ver want_sum
  want_ver="$(grep -oE 'gitleaks_[0-9]+\.[0-9]+\.[0-9]+_linux_x64\.tar\.gz' "$TT_WORKFLOW" | head -n1)"
  want_sum="$(grep -oE '[0-9a-f]{64}  /tmp/gitleaks\.tar\.gz' "$TT_WORKFLOW" | head -n1)"
  [ -n "$want_ver" ]
  [ -n "$want_sum" ]
  grep -qF "$want_ver" "$TT_CI_TESTS_WORKFLOW"
  grep -qF "$want_sum" "$TT_CI_TESTS_WORKFLOW"
}
