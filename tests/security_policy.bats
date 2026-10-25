#!/usr/bin/env bats
# Regression guard for the canonical org-wide security policy in SECURITY.md:
# Ensures that combsmith/.github/SECURITY.md uses security@combsmith.com and
# satisfies all four OpenSSF Scorecard Security-Policy evaluation probes so
# every combsmith repository inherits a 10/10 security policy by default.

SECURITY_MD="${BATS_TEST_DIRNAME}/../SECURITY.md"

@test "SECURITY.md exists at the repository root and is non-empty (securityPolicyPresent)" {
  [ -f "$SECURITY_MD" ]
  [ -s "$SECURITY_MD" ]
}

@test "SECURITY.md uses security@combsmith.com and links to private vulnerability reporting (securityPolicyContainsLinks)" {
  grep -qF 'security@combsmith.com' "$SECURITY_MD"
  grep -qE 'https://docs\.github\.com/en/code-security/security-advisories/' "$SECURITY_MD"
}

@test "SECURITY.md contains substantive explanatory text beyond links and emails (securityPolicyContainsText)" {
  text_len="$(
    sed -E \
      -e 's#https?://[a-zA-Z0-9./?=_%:-]*##g' \
      -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}##g' \
      "$SECURITY_MD" | tr -d '[:space:]' | wc -c | tr -d '[:space:]'
  )"
  [ "$text_len" -ge 200 ]
}

@test "SECURITY.md contains multiple vulnerability and timeline hints (securityPolicyContainsVulnerabilityDisclosure)" {
  hits="$(
    grep -oiE '([0-9]{1,4}|disclos|vuln)' "$SECURITY_MD" | wc -l | tr -d '[:space:]'
  )"
  [ "$hits" -gt 1 ]
  grep -qF '5 business days' "$SECURITY_MD"
}
