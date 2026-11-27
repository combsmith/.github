# ADR: SonarCloud findings are suppressed only with inline NOSONAR markers, never in the UI

- **Status:** Accepted
- **Date:** 2026-11-27
- **Scope:** every `combsmith` repository analysed by SonarCloud
- **Related standards:** [`standards/ci-standards.md` § SonarCloud suppression policy](../../standards/ci-standards.md#sonarcloud-suppression-policy),
  [S7637 exemption](../../standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637),
  [S7635 exemption](../../standards/ci-standards.md#sonarcloud-exemption-first-party-secrets-inherit-s7635)

## Context

SonarCloud offers several ways to stop a finding from counting against the
quality gate:

| Mechanism | Where it lives | Reviewed in a PR? | Travels with the code? |
|-----------|----------------|-------------------|------------------------|
| Mark issue *Accepted* / *False positive* in the web UI | SonarCloud database | No | No |
| Project *Analysis scope* / *Issues → Ignore* settings in the UI | SonarCloud database | No | No |
| Custom quality profile with rules deactivated, or a custom quality gate | SonarCloud database | No | No |
| `sonar.issue.ignore.*` / `sonar.exclusions` in `sonar-project.properties` | Repository | Yes | Per repo, not per line |
| Inline `// NOSONAR(<rule>) <reason>` on the offending line | Repository, next to the code | Yes | Yes |

UI-side changes are invisible to code review, to the compliance audit and to
agents. They carry no rationale next to the code, they are lost or diverge when
a project is re-created or a repo is forked or templated, and they cannot be
reproduced from Git. Agents in this org fix SonarCloud findings from the code
alone; a suppression they cannot see is one they will fight or duplicate.

The org already moved the two recurring GitHub Actions exemptions (S7637, S7635)
to inline markers because the marker "travels with the stub file" and needs zero
per-repo configuration. This ADR makes that the rule for every finding.

## Decision

1. **No customization in the SonarCloud UI.** Nobody, human or agent, changes
   SonarCloud's behaviour for a repository through the web console. That
   includes:
   - marking issues or security hotspots *Accepted*, *False positive*,
     *Won't fix* or *Safe*;
   - project-level analysis-scope, exclusion, ignore-issue or coverage-exclusion
     settings;
   - custom quality profiles, deactivated rules, or custom quality gates
     assigned to a project. Projects use the org default profile and gate.
2. **Suppress with an inline NOSONAR marker.** A finding that is not fixed is
   suppressed on its own line with a marker that names the rule and gives a
   reason. The rule-key syntax inside the parentheses depends on the analyzer:

   | Analyzer | Syntax | Scope of the marker |
   |----------|--------|---------------------|
   | GitHub Actions / IaC YAML | `# NOSONAR(githubactions:S7635) <reason>` | Every issue on the line. The analyzer only looks for the text `NOSONAR` and ignores the parentheses ([`NoSonarVisitor`](https://github.com/SonarSource/sonar-iac/blob/master/iac-common/src/main/java/org/sonar/iac/common/extension/visitors/NoSonarVisitor.java)); the rule key is there for reviewers and the audit. |
   | Python | `# NOSONAR(S4721) <reason>` | Only the named rules. The key must be the bare rule ID: a `python:` or `pythonsecurity:` prefix is an invalid key ([`NoSonarInfoParser`](https://github.com/SonarSource/sonar-python/blob/master/python-frontend/src/main/java/org/sonar/plugins/python/api/nosonar/NoSonarInfoParser.java)). |
   | Other languages | The analyzer's documented `NOSONAR` syntax | As documented by that analyzer. |

   ```yaml
   secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable
   ```

   ```python
   subprocess.run(cmd, shell=False)  # NOSONAR(S4721) cmd is a fixed argv list, no user input
   ```

   - Always name the rule. A bare `NOSONAR` hides what was suppressed and why,
     and is not allowed. Where the marker covers the whole line (YAML), keep
     the line to the one construct being suppressed.
   - Always give a short reason after the marker.
   - One line, one marker. No file-wide or block-wide disables.
3. **Fix first.** A marker is for a finding that is wrong for this code or
   intentionally accepted by an org standard. It is never a way to get a red
   gate green; the PR review checks each new marker's reason.
4. **`sonar-project.properties` is for analysis scope only.** It may set the
   project key, organization, report paths, and `sonar.exclusions` for code that
   is not ours and cannot carry a marker (vendored or generated code, e.g.
   `node_modules/**`). It must not add suppressions for first-party code:
   `sonar.issue.ignore.*` criteria are deprecated. The existing legacy
   per-stub S7637 and S7635 entries stay accepted only until they are migrated
   to inline markers (see Follow-up); no new ones are added.

## Consequences

- Every suppression is visible in the diff, carries its reason, and is reviewed
  like any other change.
- Suppressions survive project re-creation, repo templating and forks, and
  agents can find them with `git grep NOSONAR`.
- Any SonarCloud state that does not come from Git is drift. If a UI-side
  suppression or setting is found, it is reverted and, if still justified,
  replaced by an inline marker in a PR.

## Follow-up

- Migrate this repo's legacy `sonar.issue.ignore.multicriteria` S7637 and S7635
  entries in `sonar-project.properties` to inline markers and delete them.
- Stop the compliance audit (`check_sonar_s7637_exemption`) from counting the
  legacy properties exemption (S7637 or S7635) as compliant.
- Enforce the marker rule (named rule in the analyzer's syntax, plus a reason)
  in the compliance audit and as a PR-time CI check:
  [#1613](https://github.com/combsmith/.github/issues/1613). See
  [Enforcement](../../standards/ci-standards.md#sonarcloud-suppression-policy).
