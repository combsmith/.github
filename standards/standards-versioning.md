# Standards Versioning — the `standards/v1-stable` release channel

`standards/` in this repo is consumed by other repos as a **versioned
artifact** (repo-seeding tooling fetches `standards/workflows/`, persona
schemas, ruleset JSON, etc.). This document defines how that artifact is
published as a release channel so consumers can pin a stable, promotable
version instead of implicitly tracking this repo's default branch.

It follows the org's existing channel-tag model for reusable workflows
([`ci-standards.md` → *Reusable workflow versioning*](./ci-standards.md#reusable-workflow-versioning--the-stable-channel))
and reuses its vocabulary and guardrails. Standards are **per-repo** (one
artifact, one channel), so the shape is simpler than the per-agent concentric
rings: there is one immutable release form and one moving channel — no ring
membership, no soak gate.

## Why this exists

Before this channel, no `standards/*` tag had ever been cut, so every consumer
effectively tracked `main`. A tightening commit to a live schema then took every
consumer red the moment it merged (the propagation outage tracked in
`petry-projects/.github-private#1707`). A published, promotable channel gives
standards a **version boundary**: `main` can move freely while consumers only
see what the channel points at, and a bad promotion is one tag move away from
rollback.

## The two tag forms

| Form | Example | Mutability | Purpose |
|------|---------|------------|---------|
| **Immutable release** | `standards/vX.Y.Z` | never moved, never deleted | the audit trail and rollback target — a frozen snapshot of `standards/` at a known-good commit |
| **Moving channel** | `standards/v<major>-stable` (e.g. `standards/v1-stable`) | moved forward on promotion, back on rollback | what consumers pin — always resolves to the current published release on that major line |

This mirrors `<name>/vX.Y.Z` + `<name>/v<major>-stable` for reusable workflows.
`standards/v1-stable` is the moving channel for the v1 major line.

## Who / what moves it

- **A human decides _when_.** Cutting and promotion are deliberate operator
  actions, not automatic on merge.
- **The mechanism decides _how_.** [`scripts/cut-standards-release.sh`](../scripts/cut-standards-release.sh)
  is the only sanctioned way to cut and move the tags. It is idempotent and
  refuses to clobber an existing immutable release (see below).
- **The tags are protected.** The `release-channel-tags` ruleset
  ([`standards/rulesets/release-channel-tags.json`](./rulesets/release-channel-tags.json))
  already covers `refs/tags/**`, so `update` and `deletion` of any
  `standards/*` tag are blocked except for the authorized bypass actors (the
  org admin and the release-manager Integration apps). That is what makes
  `standards/vX.Y.Z` genuinely immutable and restricts who may move
  `standards/v1-stable`.

> **Promotion automation is intentionally out of scope** (issue #1091). The
> reusable-workflow model promotes through health-gated rings automatically; the
> standards artifact does not (yet). If that is wanted later, it should be a
> follow-up that layers a scheduled promoter on top of this same cut mechanism —
> do not build it here.

## A promotion is fleet-wide — there is no canary stage

Reusable workflows are promoted through rings, so a bad release reaches a few
repos first. The standards channel has **no rings and no canary stage**. Moving
`standards/v1-stable` changes what **every** channel consumer reads, at once.
The two steps below exist because of that: one tells the operator when a
promotion is due, the other checks that it is safe before the tag moves.

## Knowing when to promote — the staleness alarm

The channel only moves when someone cuts a release, so it can fall behind `main`
without anyone noticing. It once fell 14 commits and 8 `standards/` files behind,
and the symptom showed up in another repo's drift check.

[`standards-staleness.yml`](../.github/workflows/standards-staleness.yml) runs
once a day and compares `standards/` on the channel with the default branch. It
keeps **one** issue open while either of these holds:

- a file under `standards/workflows/` differs (alarms at once, because templates
  reach every seeded repo), or
- the oldest unpublished change to `standards/` is more than 7 days old. Set the
  repository variable `STANDARDS_STALENESS_MAX_DAYS` to change the limit.

The issue lists the differing files. Each run updates it in place, and a run
closes it once the channel has caught up. The check never promotes anything. If
it cannot read the comparison, the run fails; it never reports the channel as
fresh. The decision logic is in
[`scripts/lib/standards-staleness.sh`](../scripts/lib/standards-staleness.sh).

## Verifying before a cut

Before promoting, run every known channel consumer against the candidate commit:

```bash
bash scripts/cut-standards-release.sh verify <known-good-main-sha>
```

`verify` resolves the ref to a commit, checks out each consumer repo, and runs
its check pinned to that commit. It exits non-zero if any consumer fails. A zero
exit code alone is not a pass: a consumer that could not read the candidate may
skip its checks, so each consumer also declares the output that proves it ran.
An unreadable consumer list, an unresolvable ref and an unavailable checkout all
fail.

The consumers are data, in
[`scripts/lib/standards-channel-consumers.json`](../scripts/lib/standards-channel-consumers.json).
Today they are the repo-template drift guard and the persona manifest validator,
both in `petry-projects/.github-private`. **Add a row for every new reader of
`STANDARDS_CHANNEL` or `PERSONA_SCHEMA_CHANNEL`.**

What the operator's machine needs:

- `gh` (authenticated) and `jq`.
- GNU bash 4 or newer on `PATH` for the drift guard.
- Python 3.10 or newer with `jsonschema` and `pyyaml` for the persona validator.
  Set `PYTHON` to pick the interpreter.
- Optionally `SR_CONSUMERS_ROOT`, a directory of existing consumer checkouts, to
  verify against an unmerged consumer branch instead of a fresh clone.

Pass `--verify` to `cut` to run the same check as part of the cut. It **refuses
to cut** if any consumer fails, and writes no tag. `--verify` is opt-in so that
`cut` without it behaves exactly as before.

## Cutting a release

Run from a checkout of this repo at (or with `--commit` pointing at) a
**known-good commit on `main`** — one where CI is green and the current
`standards/` content is the intended published baseline.

```bash
# Preview (reads only; writes nothing):
bash scripts/cut-standards-release.sh cut v1.0.0 --dry-run

# Cut the immutable release standards/v1.0.0 and move standards/v1-stable onto it:
bash scripts/cut-standards-release.sh cut v1.0.0 --commit <known-good-main-sha>

# The same, refusing to cut unless every channel consumer passes (use this for a promotion):
bash scripts/cut-standards-release.sh cut v1.1.0 --commit <known-good-main-sha> --verify
```

`cut` is **idempotent**: re-running with the same version and commit is a NOOP
(the immutable tag already points there; the channel is re-aligned). It
**refuses** to re-point `standards/vX.Y.Z` to a different commit — cut a new
version instead. This mirrors `cut-release.sh`'s refusal to overwrite and
`canary-rollout.sh`'s refusal to re-point a tag that resolves elsewhere.

Tag creation is a **repo mutation**, not a file change, so it cannot land from a
PR diff. It is an explicit operator step run after the script and docs merge,
by an identity with the `release-channel-tags` bypass.

## N-1 resolvability

Policy precedent `petry-projects/.github-private#1448` requires the
compliance/drift check to accept **N-1** — the current published version _or_
the one before it — so a promotion does not instantly fail every consumer during
propagation. A consumer determines both without hardcoding anything:

```bash
bash scripts/cut-standards-release.sh resolve
# current:  standards/v1.1.0   (channel standards/v1-stable)
# previous: standards/v1.0.0   (channel standards/v1-stable)
```

**Single-version starting state.** When only one version has been cut,
`previous` is empty. That is the documented starting state, **not** a special
case a consumer must code around: a check that "accepts current OR previous"
degrades cleanly to "accepts current" while `previous` is empty.

## Opting in (and staying out)

- **Opt in** by pinning the channel: fetch `standards/` at `standards/v1-stable`
  (the drift/seed tooling in consumer repos is `petry-projects/.github-private#1707`,
  which this unblocks — out of scope here).
- **No behavior change for anything that does not opt in.** Scripts and repos
  that pass an explicit ref or a local standards directory keep resolving exactly
  as they do; this channel adds a tag, it does not change any existing
  resolution path in this repo. In particular `scripts/emit-standard-file.sh`
  (which reads a local `STANDARDS_DIR` checkout) is untouched.
