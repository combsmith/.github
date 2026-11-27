# Supply-Chain Standard — SBOM, Build Provenance & PR-time Dependency Review

> **Status:** Warn mode (rollout phase 1). Introduced by
> [#1618](https://github.com/combsmith/.github/issues/1618).

Dependabot alerts on a vulnerable dependency only after it is on `main`. This
standard adds two kinds of control. One gate runs **before merge**: a dependency
review on every pull request. Two controls make every published build
**traceable**: an SBOM and a signed build-provenance attestation. This matters
more because many org PRs are written by agents.

All three use GitHub-native actions. They are SHA-pinned under the
[Action Pinning Policy](ci-standards.md#action-pinning-policy) and need no new
secrets.

## Requirements

Every repository **in scope** (see [Scope](#scope)) MUST have all three of the
following controls in its `.github/workflows/`:

### 1. SBOM

Every release generates an SBOM in CI, in **SPDX** or **CycloneDX** JSON.

- Canonical implementation: the `Generate SBOM (SPDX)` step in
  [`workflows/release-attest.yml`](workflows/release-attest.yml)
  (`anchore/sbom-action`, `format: spdx-json`).
- Accepted alternatives: `actions/attest-sbom`, a `CycloneDX/*` generator action,
  or running `syft` / `cdxgen` / `cyclonedx-*` in a `run:` step.
- The SBOM is uploaded as a workflow artifact. Attaching it to the release as an
  asset is optional (it needs `contents: write`).

### 2. Build provenance attestation

Every published build artifact gets a signed SLSA provenance attestation from
`actions/attest-build-provenance`.

- Canonical implementation: the `Attest build provenance` step in
  [`workflows/release-attest.yml`](workflows/release-attest.yml).
- Accepted alternatives: `actions/attest` or the
  `slsa-framework/slsa-github-generator` reusable workflows.
- Required job permissions: `id-token: write` (Sigstore OIDC signing),
  `attestations: write`, and `contents: read`. Grant them to the attesting job
  only, never at the top level.
- Consumers verify with `gh attestation verify <file> --repo combsmith/<repo>`.

### 3. PR-time dependency review

Every pull request to `main` runs `actions/dependency-review-action`. It fails on newly
introduced dependencies with a **high** or **critical** advisory, or with a
denied license.

- Canonical implementation: the `dependency-review` job in
  [`workflows/ci.yml`](workflows/ci.yml).
- `fail-on-severity: high`.
- `deny-licenses`: AGPL (all versions), SSPL-1.0 and BUSL-1.1. These are
  network-copyleft or source-available licenses that conflict with the org's
  MIT-licensed distribution.
- The job runs only when `github.event_name == 'pull_request'`, because the
  action diffs the PR base and head and a push event has neither.
- Permissions: `contents: read` only. The PR summary comment is off, so the job
  needs no `pull-requests: write`.
- Needs the dependency graph. It is on by default for public repos. Private repos
  need GitHub Advanced Security (see [advanced-security.md](advanced-security.md)).

Dependency review applies to **every** repo through the `ci.yml` template. The
compliance audit only checks for it in repos that are in scope.

## Scope

A repository is **in scope** when it publishes a build artifact, that is, when
any of its workflows (full-line comments ignored):

| Signal | Examples |
|--------|----------|
| Triggers on releases | `on: release` / `on:\n  release:` |
| Uses a release or publish action | `softprops/action-gh-release`, `ncipollo/release-action`, `goreleaser/goreleaser-action`, `docker/build-push-action`, `pypa/gh-action-pypi-publish`, `JS-DevTools/npm-publish` |
| Runs a publish command | `npm`/`pnpm`/`yarn`/`cargo publish`, `twine upload`, `docker push`, `goreleaser release`, `gh release create`/`upload` |

Consuming a release (for example `gh release download`) does not put a repo in
scope. A repo that publishes nothing needs no SBOM or attestation. It still gets
dependency review from `ci.yml`.

`compliance-audit.sh` uses the same signals (`supply_chain_publishes_artifacts`).
If you change the list above, change the function too, and the reverse.

## Adoption

1. **Dependency review.** Copy the `dependency-review` job from
   [`workflows/ci.yml`](workflows/ci.yml) into the repo's `ci.yml` verbatim.
   Keep the job name, the `if:` and the pinned SHA. New repos get it from
   `repo-template`.
2. **SBOM + provenance.** Copy [`workflows/release-attest.yml`](workflows/release-attest.yml)
   and replace its placeholder build step with the real build. Point
   `SUBJECT_PATH` at the build outputs. The placeholder fails on purpose, so a
   release never ships an attestation for an artifact that was not built. If an
   existing release job already builds the artifact, copy the SBOM and attest
   steps (with the job's permissions) into that job instead.

## Exemptions

Exemptions are recorded in the `supply_chain_exemptions` array in
[`workflow-exemptions.json`](workflow-exemptions.json):

```json
{
  "supply_chain_exemptions": [
    {
      "repo": "example-repo",
      "controls": ["sbom", "provenance"],
      "reason": "Publishes only a docs site; no consumable build artifact."
    }
  ]
}
```

- `controls` is one or more of `dependency-review`, `sbom` and `provenance`.
- `reason` is **required**. The audit ignores an entry without one, so a gap can
  never be waived silently.
- Adding an exemption is a standards change and needs human review in a
  `combsmith/.github` PR. Agents must not add exemptions to clear their own
  findings.

The list starts empty.

## Compliance audit

`check_supply_chain` in [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)
reads every workflow in each repo. For a repo in scope, it reports one finding
per control that is missing and not exempted:

| Check id | Control |
|----------|---------|
| `supply-chain-missing-dependency-review` | `actions/dependency-review-action` |
| `supply-chain-missing-sbom` | SPDX/CycloneDX SBOM generation |
| `supply-chain-missing-provenance` | `actions/attest-build-provenance` (or accepted alternative) |

The findings use category `supply-chain`. If any workflow file cannot be read,
the repo is marked inconclusive instead of reported, so a read failure never
auto-closes an open finding.

## Rollout: warn, then enforce

The org rolls this out the same way as its other checks:

| Phase | When | Audit severity | `dependency-review` job |
|-------|------|----------------|-------------------------|
| **1. Warn** (current) | From adoption of this standard | `warning` | `warn-only: true` plus step-level `continue-on-error: true`. It reports in the job summary and never blocks. |
| **2. Enforce** | After two consecutive weekly audits show no unexempted `supply-chain-*` findings, and at least 30 days after phase 1 | `error` | Remove `warn-only` and `continue-on-error`. A high-severity or denied-license dependency fails the job. |

Moving to phase 2 is a standards PR that a human must approve. It changes the
severity in `check_supply_chain` and the two lines in `workflows/ci.yml`, and
re-deploys. Whether `dependency-review` becomes a **required** status check is
a separate decision under the
[ruleset process](github-settings.md). It is out of scope here.
