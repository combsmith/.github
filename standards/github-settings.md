# GitHub Repository Settings Standards

Standard configurations for all repositories in the **combsmith** organization.
These settings are enforced via the GitHub UI, API, and repository rulesets.

---

## Organization-Level Settings

| Setting | Value | Notes |
|---------|-------|-------|
| **Default repository permission** | `read` | Least privilege; grant write/admin via teams |
| **Organization profile** | `combsmith` | Public org (free plan) |
| **Default branch name** | `main` | Org-wide default for new repos |
| **Members can create repos** | Yes (public + private) | |
| **Two-factor requirement** | **Required** | All org members must have 2FA enabled |

---

## Repository Settings — Standard Defaults

All new repositories MUST be created with these settings. Existing repositories
SHOULD be audited and brought into compliance.

### General

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Default branch** | `main` | All repos use `main` |
| **Visibility** | `public` | Default for org repos; private repos require justification |
| **Has Issues** | `true` | Issue tracking enabled on all repos |
| **Has Projects** | `true` | Currently enabled on all repos |
| **Has Wiki** | `false` | Disabled — documentation lives in the repo |
| **Has Discussions** | `true` | **Required** — enables Discussions for ideation, feedback, and community engagement (see [Discussions Configuration](#discussions-configuration)) |

### Security & Analysis

All repositories MUST have the following security features enabled. These are
the enforcement primitives behind the [Push Protection Standard](push-protection.md).
They are enabled org-wide via the "GitHub recommended" code security
configuration — see the [Advanced Security (GHAS) Standard](advanced-security.md).

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Secret scanning** | `enabled` | Detect leaked credentials in history and new commits |
| **Secret scanning push protection** | `enabled` | Block pushes containing known secret patterns at the server side |
| **Secret scanning AI detection** | `enabled` | Catch generic secrets missed by regex patterns |
| **Secret scanning non-provider patterns** | `enabled` | Private keys, HTTP basic auth, high-entropy strings |
| **Dependabot security updates** | `enabled` | Automated patches for known-vulnerable dependencies |

> See the full requirements, custom patterns, CI job, incident response flow,
> and compliance audit checks in [`push-protection.md`](push-protection.md).

### Merge Settings

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Allow squash merging** | `true` | **Primary merge method** — enforced by `pr-quality` ruleset |
| **Allow merge commits** | `true` | Enabled to avoid conflicts with admin overrides; `pr-quality` ruleset enforces squash-only |
| **Allow rebase merging** | `true` | Enabled to avoid conflicts with admin overrides; `pr-quality` ruleset enforces squash-only |
| **Allow auto-merge** | `true` | Required for Dependabot auto-merge workflow |
| **Automatically delete head branches** | `true` | Clean up merged branches automatically |
| **Default squash merge commit title** | `PR_TITLE` | Clean, descriptive commit history |
| **Default squash merge commit message** | Commit messages (`COMMIT_MESSAGES`) | Preserves individual commit messages |

> **Note:** While merge commits and rebase merging are enabled at the repository
> level, the `pr-quality` ruleset enforces **squash-only** merges. The repo-level
> settings are permissive to avoid conflicts with admin overrides when needed.

---

## Discussions Configuration

GitHub Discussions MUST be enabled on all repositories. Discussions serve as the
durable, threaded home for feature ideation, design proposals, and community
feedback — distinct from Issues (which track actionable work).

### Required Discussion Categories

All repositories MUST have the following categories configured:

| Category | Format | Emoji | Description |
|----------|--------|-------|-------------|
| **Ideas** | Open-ended | `💡` | Feature proposals, ideation threads, and innovation exploration |
| **General** | Open-ended | `💬` | General project discussions and questions |

Additional categories MAY be added per project needs (e.g., "Q&A", "Show and Tell",
"Polls"). The two above are the required minimum.

### Automated Ideation Workflow

Repositories with the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD)
installed (`_bmad/` directory) MUST have the `feature-ideation.yml` workflow,
which uses the **Ideas** category to post and maintain feature proposal
Discussions. Each proposal is a separate Discussion thread, updated by subsequent
workflow runs as market signals and project context evolve. See
[CI Standards § Feature Ideation](ci-standards.md#8-feature-ideation-feature-ideationyml-bmad-method-repos)
for requirements.

### Setup

To enable and configure Discussions on an existing repository:

```bash
# Enable Discussions
gh api -X PATCH repos/<owner>/<repo> -f has_discussions=true

# Discussion categories are managed via the GitHub UI:
# Settings → General → Features → Discussions → Set up discussions
# Or via GraphQL after initial setup.
```

> **Note:** Discussion categories cannot currently be created via the REST API.
> Use the GitHub UI or GraphQL `createDiscussionCategory` mutation. The compliance
> audit checks that Discussions are enabled; category configuration is verified
> manually during onboarding.

---

## Repository Rulesets

Rulesets are the primary enforcement mechanism for branch policies. All
repositories MUST use rulesets on the default branch. Classic branch protection
rules are deprecated — migrate existing classic rules to rulesets.

**`pr-quality` and `code-quality` are the only sanctioned rulesets.** Legacy
`protect-branches` rulesets and ad-hoc `main` rulesets are deprecated: they
duplicate protections and, because GitHub evaluates bypass eligibility per
ruleset, they are a second place every bypass actor must be kept in sync (the
trap that produced inconsistent `OrganizationAdmin` / `RepositoryAdmin` bypass
state across the fleet). They MUST be migrated into the two sanctioned rulesets
and removed. Deletion is only safe once every required status check the legacy
ruleset carries is ALSO required by a sanctioned ruleset — otherwise deletion
silently drops a merge gate. `check_legacy_rulesets()` in
[`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh) flags each
legacy ruleset and reports the exact migration delta (checks to move into
`code-quality` first, or "safe to delete").

> **Remediating ruleset findings is a manual, admin-token procedure** —
> `compliance-remediate.sh` skips the `rulesets` category. Follow the
> [Ruleset Remediation Runbook](ruleset-remediation-runbook.md) (snapshot →
> bypass actors → migrate-then-delete legacy → verify → rollback).

### Bypass Actors — Required on Every Ruleset Targeting `main`

**The `dependabot-automerge-petry` GitHub App MUST be a bypass actor on every
ruleset that targets the default branch**, not only on `pr-quality`. GitHub
evaluates bypass eligibility independently per ruleset — having bypass in
`pr-quality` does NOT grant bypass in `protect-branches`, `main`, or any other
ruleset applied to the same branch. Every such ruleset must include:

| Actor | Type | `bypass_mode` | Reason |
|-------|------|--------------|--------|
| `dependabot-automerge-petry` | GitHub App | `always` | Merges Dependabot PRs via API; rejected without bypass in every active ruleset |
| `OrganizationAdmin` | Role | `always` | Emergency admin override |

**Why `bypass_mode: always`:** `pull_request` bypass mode only works when the
bypass actor *opens* the PR. Dependabot opens its own PRs, so the
`dependabot-automerge-petry` app cannot use that mode — its merge API calls are
rejected. `always` mode is safe here because the rebase workflow explicitly
verifies CI pass and `MERGEABLE` state before calling the merge API.

**Remediation — `scripts/fix-ruleset-bypass.sh`:** normalizes bypass actors on
**every** ruleset targeting the default branch (including legacy
`protect-branches` / `main` rulesets that `apply-rulesets.sh` does not manage).
Existing actors are preserved; the two required actors are added/normalized to
`bypass_mode: always`. Dry-run emits ready-to-PUT payloads for review without
mutating live rulesets:

```bash
# Preview payloads for one repo (or --all):
GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh <repo> --dry-run

# Apply:
GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh --all
```

> `apply-rulesets.sh` full-replaces `pr-quality` / `code-quality` with the two
> canonical bypass actors. `fix-ruleset-bypass.sh` is the least-destructive,
> any-ruleset complement used to remediate audit findings.

**Compliance check:** enforced automatically by the weekly audit —
`check_ruleset_bypass_actors()` in [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)
verifies that every ruleset targeting the default branch grants `bypass_mode:
always` to both required actors, and flags the `Repository admin` role
(`RepositoryRole` id 5) as a non-conforming substitute for `OrganizationAdmin`.

### `pr-quality` — Standard Ruleset (All Repositories)

| Setting | Value |
|---------|-------|
| **Target branches** | Default branch (`main`) |
| **Enforcement** | Active |
| **Required approving reviews** | 1 |
| **Dismiss stale reviews on push** | **Yes** — prevents merging unreviewed code after approval |
| **Required review thread resolution** | **Yes** — all threads must be Resolved before merge |
| **Require code owner review** | **Yes** — requires approval from a CODEOWNERS-defined owner |
| **Require last push approval** | **Yes** — ensures different people review substantive code changes; Dependabot rebase workflow re-approves after branch updates to maintain approval validity |
| **Allow auto-merge** | **Yes** — enables automatic merge when all status checks pass and requirements are satisfied |
| **Allowed merge methods** | **Squash only** |
| **Allow force pushes** | No |
| **Allow deletions** | No |

> **CODEOWNERS:** All repos MUST have a `CODEOWNERS` file. Without one, the
> "Require code owner review" setting has no effect. See the
> [CODEOWNERS Standard](#codeowners-standard) below for the required format.

#### Auto-Merge Configuration

The **Allow auto-merge** setting enables PRs to merge automatically once all status checks pass and review requirements are satisfied. This is required for:

- **Dependabot auto-merge workflows** — enables `gh pr merge --auto` API calls
- **Agentic PR automation** — CI/CD agents can queue PRs for automatic merge after approval and check passage
- **Efficient CI workflows** — avoids manual merge steps when all quality gates have passed

Auto-merge is a **safe setting** because the ruleset still enforces all approval and review requirements before
the merge occurs — the automation only handles the final merge step after human review and all CI checks pass.
See [GitHub's auto-merge documentation](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)
for more details.

#### Bypass Actors

See [Bypass Actors — Required on Every Ruleset Targeting `main`](#bypass-actors--required-on-every-ruleset-targeting-main) above.
The same `dependabot-automerge-petry` + `OrganizationAdmin` bypass actors MUST appear in `pr-quality` and in every other ruleset that targets `main`.

#### CODEOWNERS Approval Timing

GitHub evaluates code owner status **at the time an approval is submitted**, not
retroactively. If `CODEOWNERS` is updated (e.g., adding bot accounts), approvals
already on open PRs from those accounts are not retroactively credited as code
owner approvals.

**Recovery:** comment `@dependabot rebase` on blocked PRs. This triggers
Dependabot to push a new commit, which fires the automerge workflow and submits
a fresh approval under the current CODEOWNERS.

### `code-quality` — Required Checks Ruleset (All Repositories)

Every repository MUST have the following quality checks configured and
required. The specific check names and ecosystem configurations vary by repo,
but the categories are universal.

#### Required Check Categories

| Check | Required | Check Name(s) | Notes |
|-------|----------|---------------|-------|
| **SonarCloud** | All repos | `SonarCloud` | Code quality, maintainability, security hotspots |
| **CodeQL** | All repos | `CodeQL` | SAST via GitHub-managed default setup — auto-detects all supported languages (see [ci-standards.md §2](ci-standards.md#2-codeql-analysis-github-managed-default-setup)) |
| **Dev-Lead Agent** | All repos | `Dev-Lead Agent / dev-lead` | AI code review and agent automation on every PR |
| **CI Pipeline** | All repos | Repo-specific (e.g., `build-and-test`, `TypeScript`, `Go`) | Lint, format, typecheck, test |
| **Coverage** | All repos | `coverage` or embedded in CI job | Must meet repo-defined thresholds |
| **Secret Scan** | All repos | `Secret scan (gitleaks)` | Full-history gitleaks scan — see [Push Protection Standard](push-protection.md#layer-3--ci-secret-scanning-secondary-defense) |

> **Check names must match exactly.** GitHub-managed CodeQL produces a check named
> `CodeQL` — **not** `Analyze (actions)`, `Analyze (javascript-typescript)`, or
> `CodeQL / Analyze (go)`. Requiring a check name that no job produces permanently
> blocks every PR. Verify check names against actual workflow runs:
>
> ```bash
> gh pr checks <PR-number> --repo combsmith/<repo>
> ```

#### Ecosystem-Specific Configuration

The ecosystems scanned by each check depend on which languages/tools the repo
contains. If a repo contains an ecosystem, that ecosystem MUST be configured
in the relevant checks:

| Ecosystem Detected | CodeQL Language | SonarCloud | CI Pipeline | Dependency Audit |
|--------------------|----------------|------------|-------------|------------------|
| `package.json` / `package-lock.json` | `javascript-typescript` | JS/TS analysis | npm/pnpm lint, typecheck, test | `npm audit` or `pnpm audit` |
| `go.mod` | `go` | Go analysis | `go vet`, `golangci-lint`, `go test` | `govulncheck` |
| `Cargo.toml` | `rust` (if supported) | Rust analysis | `cargo fmt`, `cargo check`, `cargo test` | `cargo audit` |
| `pyproject.toml` / `requirements.txt` | `python` | Python analysis | pytest, coverage | `pip-audit` |
| `.github/workflows/*.yml` | `actions` | — | — | — |
| `*.tf` (Terraform) | — | — | `terraform validate` | Dependabot security updates |
| `_bmad/` (BMAD Method) | — | — | `feature-ideation.yml` (weekly) | — |

Multi-language repos (e.g., TypeScript + Go) MUST configure all applicable
ecosystems in each check.

#### Additional Settings

| Setting | Value |
|---------|-------|
| **Require branches to be up to date** | Yes (`strict: true`) |
| **Enforce for admins** | Yes |

See [CI Standards](ci-standards.md) for workflow templates and patterns.

---

## GitHub Apps & Integrations

### Installed GitHub Apps (org-wide, all repos)

| App | Purpose | Installed |
|-----|---------|-----------|
| **Claude** | AI code review and PR assistance via Claude Code Action (default dev-lead engine) | 2026-03-20 |
| **dependabot-automerge-petry** | Provides approving review for Dependabot auto-merge | 2026-03-23 |
| **petry-projects-pr-review-agent** | (deprecated) GitHub App formerly used for PR review — replaced by `donpetry-bot` machine user in `@combsmith/org-leads` because Apps cannot be CODEOWNERS | 2026-04-01 |
| **donpetry-bot** | Machine-user account in `@combsmith/org-leads`; satisfies CODEOWNERS for automated PR review | 2026-05-04 |
| **SonarQube Cloud (SonarCloud)** | Code quality, security hotspots, coverage tracking | 2026-03-25 |
| **CodeRabbit AI** | AI-powered code review on PRs | 2026-03-25 |

### AI Engine Support — Dev-Lead Workflow

The **dev-lead agent** workflow (`dev-lead.yml`) supports multiple AI engines for PR review and automation.
Set `vars.DEV_LEAD_ENGINE` per-repo to choose the engine; defaults to `claude`.

| Engine | Engine ID | Required Secrets | Purpose | Status |
|--------|-----------|-----------------|---------|--------|
| **Claude** | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` | Anthropic Claude models for code review | Active (default) |
| **Gemini** | `gemini` | `CLAUDE_CODE_OAUTH_TOKEN`, `GOOGLE_API_KEY` | Google Gemini for code review (fallback if Claude unavailable) | Supported |
| **Copilot** | `copilot` | `CLAUDE_CODE_OAUTH_TOKEN`, `GH_PAT` | GitHub Copilot for code review (GitHub-native alternative) | Supported |

**Configuration per-repo (set as a repository variable):**

```bash
# GitHub does not propagate caller workflow env: values into called reusable
# workflows, so setting env: in the caller stub has no effect. Use a repository
# variable instead, which the reusable workflow reads as vars.DEV_LEAD_ENGINE.
gh variable set DEV_LEAD_ENGINE --body "gemini" --repo combsmith/<repo>
# Alternatively: Settings → Secrets and variables → Actions → Variables → New variable
```

**Secret requirements by engine:**

- **Claude**: requires `CLAUDE_CODE_OAUTH_TOKEN` only
- **Gemini**: requires `CLAUDE_CODE_OAUTH_TOKEN` + `GOOGLE_API_KEY`
- **Copilot**: requires `CLAUDE_CODE_OAUTH_TOKEN` + `GH_PAT` (GitHub token with Copilot scope)

### Check-Suite Auto-Trigger Preferences

GitHub automatically creates a check suite for any app that has previously created check runs in a repo, on every push.
Some apps (Claude, CodeRabbit, and alternative AI engines) create these suites proactively but only complete them when they have real work to do.
When they have nothing to do, the suite stays in `queued` state indefinitely —
**GitHub auto-merge waits for all check suites to reach a terminal state before merging**,
so these orphaned suites permanently block auto-merge.

**Required configuration** (enforced by `scripts/apply-repo-settings.sh` and detected by `scripts/compliance-audit.sh`):

| App | app_id | Setting |
|-----|--------|---------|
| Claude (`anthropics/claude-code-action`) | `1236702` | `auto_trigger_checks: false` |
| CodeRabbit | `347564` | `auto_trigger_checks: false` |

Disabling auto-trigger stops GitHub from creating suites on every push. The apps still create suites explicitly when they have work to report.

If an app has never created a check run in a repository, GitHub omits that app from `auto_trigger_checks` entirely.
Both `scripts/apply-repo-settings.sh` and `scripts/compliance-audit.sh` treat this `missing` state as compliant —
no PATCH is needed and no finding is raised until the app is first seen in the repo.

**Additional AI engines** (Gemini, Copilot) — if a repo activates an alternative `DEV_LEAD_ENGINE`:
Verify that the corresponding app has `auto_trigger_checks: false` set if/when it first creates a check run.

**Applying manually** (requires a classic PAT with `repo` scope — OAuth app tokens are rejected by this API endpoint):

```bash
GH_TOKEN=<classic-pat> bash scripts/apply-repo-settings.sh <repo-name>
# or for all org repos:
GH_TOKEN=<classic-pat> bash scripts/apply-repo-settings.sh --all
```

### Other Integrations

| Integration | Purpose | Scope |
|-------------|---------|-------|
| **GitHub Copilot** | AI code review (native GitHub feature) | All repos |
| **CodeQL** | Static analysis (SAST) via GitHub Actions | Repos with CodeQL workflows |
| **Dependabot** | Security updates for dependencies | All repos (see [Dependabot Policy](dependabot-policy.md)) |

### Organization-Level Secrets for Standard CI

These secrets are configured at the **organization level** and inherited by
all repos automatically — no per-repo setup needed:

#### Required secrets (all repos)

| Secret | Purpose |
|--------|---------|
| `APP_ID` | GitHub App ID for Dependabot auto-merge (app_id: 3167543) |
| `APP_PRIVATE_KEY` | GitHub App private key for Dependabot auto-merge |
| `CLAUDE_CODE_OAUTH_TOKEN` | Authentication for Claude Code Action and dev-lead agent (default engine) |
| `DON_PETRY_BOT_GH_PAT` | Classic PAT (repo scope) owned by donpetry-bot; required by `pr-review-mention-reusable.yml` to post review-mention comments as the bot identity |
| `GH_PAT_WORKFLOWS` | Classic PAT with `repo` scope; required for cross-repo script access and dev-lead to push workflow files |
| `GITLEAKS_LICENSE` | Gitleaks license key required for `secret-scan` job in organization repositories (see [ci-standards.md](ci-standards.md#4-secret-scanning-ciymll--gitleaks-job)) |
| `SONAR_TOKEN` | SonarCloud analysis authentication |

#### Optional secrets (by feature)

| Secret | Purpose | Required for |
|--------|---------|---------------|
| `GOOGLE_API_KEY` | Gemini API authentication | Repos using `vars.DEV_LEAD_ENGINE=gemini` |
| `GH_PAT` | GitHub token with Copilot scope | Repos using `vars.DEV_LEAD_ENGINE=copilot` |

Repos may require repo-specific secrets beyond this standard set.

---

## Labels — Standard Set

All repositories MUST have these labels configured:

| Label | Color | Purpose |
|-------|-------|---------|
| `security` | `#d93f0b` (red) | Security-related PRs and issues |
| `dependencies` | `#0075ca` (blue) | Dependency update PRs |
| `scorecard` | `#d93f0b` (red) | OpenSSF Scorecard findings (auto-created) |
| `bug` | `#d73a4a` (red) | Bug reports |
| `enhancement` | `#a2eeef` (teal) | Feature requests |
| `documentation` | `#0075ca` (blue) | Documentation changes |
| `in-progress` | `#fbca04` (yellow) | An agent is actively working this issue |

---

## CODEOWNERS Standard

All repositories MUST have a `CODEOWNERS` file at `.github/CODEOWNERS`
(or `CODEOWNERS` at the repo root for repos with no `.github/` directory).

The full policy lives in [`codeowners-standard.md`](codeowners-standard.md).
Summary:

- The default owner line MUST be `* @combsmith/org-leads`
- Direct listings of users or bot accounts (e.g.,
  `@petry-projects-pr-review-agent`, `@dependabot-automerge-petry`) are
  **forbidden** — manage membership through the team instead
- GitHub Apps cannot be code owners (platform limitation); use machine-user
  accounts added to the team

### Standard Template

```gitignore
# CODEOWNERS
# Standard: https://github.com/combsmith/.github/blob/main/standards/codeowners-standard.md

* @combsmith/org-leads
```

Repos with finer-grained path ownership MUST include `@combsmith/org-leads`
on every owner line so the team can always satisfy `require_code_owner_review`.

---

## Applying to a New Repository

When creating a new repository in `combsmith`:

1. **Create the repo** with standard settings (public, `main` branch, wiki disabled, discussions enabled)
2. **Create the `pr-quality` ruleset** matching the standard configuration above, including:
   - Bypass actors with `bypass_mode: always` for `dependabot-automerge-petry` and `OrganizationAdmin`
   - **Allow auto-merge enabled** — in the ruleset's "Merge settings", check the "Allow auto-merge" option.
     Required for seamless PR automation and CI-dependent merges
3. **Create the `code-quality` ruleset** with required checks for the repo's stack — verify check names against actual workflow runs before requiring them
4. **Add a `CODEOWNERS` file** using the [CODEOWNERS Standard](#codeowners-standard) template, extended with any repo-specific path patterns
5. **Add Dependabot configuration** — copy the appropriate template from
   [`standards/dependabot/`](dependabot/) and add to `.github/dependabot.yml`
6. **Add CI workflows** — see [CI Standards](ci-standards.md) for required workflows
7. **Create standard labels** — all labels from the [Standard Set](#labels--standard-set) above, plus any project-specific labels
8. **Enable auto-delete head branches** in repo settings
9. **Connect integrations** — ensure CodeRabbit and SonarCloud (if applicable) are enabled

> **Note:** All standard CI secrets are configured at the org level and inherited
> automatically — see [Organization-Level Secrets](#organization-level-secrets-for-standard-ci).
> No per-repo secret setup is needed for standard CI workflows.

---

## Organization-Level Workflows

The org runs several automated workflows across all repositories:

| Workflow | Schedule | Purpose | Details |
|----------|----------|---------|---------|
| **Actions Fleet Monitor** (`actions-fleet-monitor.yml` in `combsmith/.github-private`) | Daily, 6:00 UTC | Monitor health of all GitHub Actions workflows across the org | Tracks success/failure rates, duration percentiles (p50/p95), and assigns status (HEALTHY/WARNING/DEGRADED/CRITICAL) per workflow; creates issues when workflows have failures |
| **Org Scorecard Review** (`org-scorecard.yml`) | Weekly, Monday 9:00 UTC | Security posture scoring for all public repos via OpenSSF Scorecard | Creates/updates/closes GitHub Issues with findings; auto-closes when resolved |
| **Org Standards Compliance Audit** (`compliance-audit-and-improvement.yml`) | Weekly, Friday 12:00 UTC | Deterministic audit of all repos against org standards + runtime health survey | Identifies missing workflows, misconfigured settings, stale PRs, security alerts; creates actionable issues labeled `dev-lead` for agent remediation |
| **Daily Org Status** (`daily-org-status.yml`) | Daily, 6:00 UTC | Org-wide health snapshot — PR counts, CI failures, dependency vulnerabilities | Reports via PR comments and workflow summary |
| **Dependency Audit** (`dependency-audit.yml`) | Per-repo CI (push/PR to `main`) | Multi-ecosystem dependency vulnerability scan (npm, pnpm, go, cargo, pip) | Fails the build when dependencies have known security advisories; adopted per-repo via the standard caller stub |

### Actions Fleet Monitor Details

The **Actions Fleet Monitor** runs daily and provides critical visibility into workflow health:

**Metrics tracked per workflow:**

- Total runs, successful runs, failed runs, cancelled runs (over lookback window)
- Failure rate (`failed / total`)
- Duration percentiles (p50 and p95)
- Health status: `HEALTHY` (0% failures), `WARNING` (>0%, ≤20%), `DEGRADED` (>20%, ≤50%), `CRITICAL` (>50%)

**Lookback window:** Defaults to 1 day; can be customized with `--field lookback_days=N` when running manually

**Results delivery:**

- Step Summary — workflow results table displayed in GitHub Actions UI (visible on every run)
- GitHub Issue — created in `.github-private` when any workflow has failed runs

**Manual trigger:**

```bash
gh workflow run actions-fleet-monitor.yml \
  --repo combsmith/.github-private \
  --field org=combsmith \
  --field lookback_days=7
```

This tool is essential for detecting CI flakiness, performance degradation, and systemic workflow issues before they impact development velocity.

**Ruleset bypass actors & legacy rulesets (remediated 2026-06-10):** a full
sweep (now enforced by `check_ruleset_bypass_actors()` and
`check_legacy_rulesets()`) found `.github-private` already compliant and every
other repo carrying findings — `code-quality` rulesets missing the
`dependabot-automerge-petry` bypass, `pr-quality` rulesets granting
`RepositoryAdmin` where `OrganizationAdmin` is required, and four deprecated
legacy rulesets still active. **All have been remediated.** A re-audit reports
**zero ruleset findings** across the fleet.

| Repository | Bypass actors | Legacy ruleset | Action taken |
|------------|:---:|:---:|-------|
| **.github-private** | ✅ | — | Already compliant |
| **.github** | ✅ | retired | `code-quality` dependabot bypass added; `protect-branches` deleted |
| **bmad-bgreat-suite** | ✅ | retired | `code-quality` bypass actors added; `protect-branches` deleted |
| **ContentTwin** | ✅ | — | `code-quality` dependabot bypass added; `pr-quality` OrganizationAdmin added |
| **broodly** | ✅ | — | `code-quality` dependabot bypass added; `pr-quality` OrganizationAdmin + dependabot added |
| **markets** | ✅ | — | `code-quality` bypass actors added; `pr-quality` OrganizationAdmin + dependabot added |
| **TalkTerm** | ✅ | retired | `code-quality` dependabot bypass added; redundant `main` ruleset deleted |
| **google-app-scripts** | ✅ | retired | `coverage` migrated into `code-quality`, then `protect-branches` deleted; `code-quality` bypass actors added |

> **Remediation:** see the [Ruleset Remediation Runbook](ruleset-remediation-runbook.md).
> Tooling: `scripts/fix-ruleset-bypass.sh` (bypass actors, least-destructive,
> dry-run capable) and `scripts/apply-rulesets.sh` (canonical `pr-quality` /
> `code-quality`). Legacy rulesets are retired with
> `gh api -X DELETE repos/combsmith/<repo>/rulesets/<id>` once
> `check_legacy_rulesets()` reports an empty migration delta.

---

## Audit & Compliance

### Compliance Audit Process

Every Friday at 12:00 UTC, the **Org Standards Compliance Audit** runs across all repositories:

1. **Deterministic compliance checks** (`scripts/compliance-audit.sh`) verify each repo meets org standards:
   - Required workflows present (CI, CodeQL, dev-lead agent, Dependabot, etc.)
   - Branch protection rules and rulesets correctly configured
   - Labels, CODEOWNERS, and settings match the standard
   - GitHub App auto-trigger preferences set correctly

2. **Runtime health survey** checks:
   - CI failures and flaky tests
   - Stale pull requests (open > 14 days)
   - Security alerts (CodeQL, Dependabot, secret scanning)
   - Dependency vulnerabilities

3. **Issue creation and categorization:**
   - Each finding becomes a GitHub Issue in the repository, labeled `compliance-audit`
   - High-priority findings (errors) are escalated for immediate remediation
   - Issues include a `dev-lead` label for agent-driven automation
   - Fixed issues are auto-closed by the audit

4. **Org-level summary and reporting:**
   - Overall compliance health report
   - Trend analysis and improvement suggestions
   - Published as a GitHub Issue in the `.github` repository

### Scorecard Results

The weekly [OpenSSF Scorecard](https://github.com/ossf/scorecard) audit via
[`org-scorecard.yml`](../.github/workflows/org-scorecard.yml) scans all public repos:

- Creates/updates GitHub Issues for findings (labeled `scorecard`)
- Auto-closes issues when checks reach a score of 10/10
- Produces a summary report in the workflow step summary

Scorecard findings should be reviewed and remediated per the
[OpenSSF Scorecard documentation](https://github.com/ossf/scorecard/blob/main/docs/checks.md).
