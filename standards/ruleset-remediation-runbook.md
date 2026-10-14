# Runbook — Ruleset Remediation (Bypass Actors & Legacy Rulesets)

Manual procedure for remediating repository-ruleset findings raised by the
weekly compliance audit (`check_ruleset_bypass_actors()` and
`check_legacy_rulesets()` in [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)).

> **Why this is manual.** Ruleset changes are **not** auto-remediated.
> [`scripts/compliance-remediate.sh`](../scripts/compliance-remediate.sh)
> classifies the `rulesets` category as *"requires admin API access — run
> scripts/apply-rulesets.sh or use the GitHub UI"* and skips it. Ruleset
> `PUT`/`DELETE` needs an **admin token** (`admin:org` + `repo`, or
> `administration:write`) that the CI `GITHUB_TOKEN` does not carry — so these
> findings are detected and filed every week but never auto-applied. Run this
> runbook with an admin token to close them.

See [`github-settings.md` § Repository Rulesets](github-settings.md#repository-rulesets)
for the policy this enforces:

- **`pr-quality` and `code-quality` are the only sanctioned rulesets.** Legacy
  `protect-branches` and ad-hoc `main` rulesets are deprecated and must be
  migrated into the two sanctioned rulesets and removed.
- **Every ruleset targeting the default branch** must grant `bypass_mode: always`
  to both `OrganizationAdmin` and the `dependabot-automerge-petry` app
  (Integration `3167543`). GitHub evaluates bypass per ruleset, so a duplicate
  ruleset is a second place every bypass actor must be kept in sync.

---

## 0. Prerequisites

```bash
gh auth status            # token must have admin:org + repo
export GH_TOKEN="$(gh auth token)"
ORG=combsmith
```

## 1. Snapshot every ruleset (rollback insurance) — ALWAYS do this first

```bash
SNAP="$HOME/ruleset-snapshots/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$SNAP"
for repo in $(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500); do
  gh api "repos/$ORG/$repo/rulesets" > "$SNAP/${repo}__rulesets-list.json"
  for id in $(jq -r '.[].id' < "$SNAP/${repo}__rulesets-list.json"); do
    gh api "repos/$ORG/$repo/rulesets/$id" > "$SNAP/${repo}__${id}.json"
  done
done
echo "Snapshot: $SNAP"
```

## 2. Bypass actors — additive, reversible

[`scripts/fix-ruleset-bypass.sh`](../scripts/fix-ruleset-bypass.sh) normalizes
bypass actors on **every** default-branch ruleset (including legacy ones), adding
`OrganizationAdmin` + the dependabot app, both `bypass_mode: always`, while
preserving any existing actors. Already-compliant rulesets are skipped.

```bash
# Preview ready-to-PUT payloads (writes to a temp dir, no mutation):
./scripts/fix-ruleset-bypass.sh --all --dry-run
# Apply:
./scripts/fix-ruleset-bypass.sh --all
# Single repo:
./scripts/fix-ruleset-bypass.sh <repo>
```

> `apply-rulesets.sh` full-replaces `pr-quality` / `code-quality` from the codified
> `standards/rulesets/*.json` (which carry the two canonical bypass actors);
> `fix-ruleset-bypass.sh` is the least-destructive, any-ruleset complement used to
> remediate audit findings.

## 3. Legacy rulesets — migrate checks first, THEN delete

A legacy ruleset is safe to delete only when `check_legacy_rulesets()` reports an
**empty migration delta** — i.e. every required status check it carries is also
required by a sanctioned ruleset. If it carries a unique check, migrate that
check into `code-quality` **before** deleting, or deletion silently drops a merge
gate.

### 3a. Migrate a missing check into `code-quality`

Rebuild the `PUT` body from the live `GET`. Required-check entries are bare
`{"context":"..."}` — do **not** add an `integration_id` field; the API rejects
it with `422 Invalid request`.

```bash
repo=<repo>; new_check="coverage"   # example
cqid=$(gh api "repos/$ORG/$repo/rulesets" --jq '.[]|select(.name=="code-quality")|.id')
gh api "repos/$ORG/$repo/rulesets/$cqid" | jq --arg c "$new_check" '{
  name, target, enforcement, conditions, bypass_actors,
  rules: (.rules | map(
    if .type=="required_status_checks" then
      .parameters.required_status_checks |= (
        if (map(.context)|index($c))==null then . + [{"context":$c}] else . end)
    else . end))
}' | gh api -X PUT "repos/$ORG/$repo/rulesets/$cqid" --input -
```

### 3b. Delete a legacy ruleset, guarded by a final empty-delta re-check

```bash
repo=<repo>; lname=<protect-branches|main>
list=$(gh api "repos/$ORG/$repo/rulesets")
lid=$(echo "$list" | jq -r --arg n "$lname" '.[]|select(.name==$n)|.id')
sanctioned=$(for sid in $(echo "$list" | jq -r '.[]|select(.name=="pr-quality" or .name=="code-quality")|.id'); do
  gh api "repos/$ORG/$repo/rulesets/$sid" --jq '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[]?.context]|.[]'; done)
uncovered=""
while IFS= read -r c; do
  [ -z "$c" ] && continue
  grep -qxF "$c" <<< "$sanctioned" || uncovered+="$c "
done < <(gh api "repos/$ORG/$repo/rulesets/$lid" --jq '[.rules[]?|select(.type=="required_status_checks")|.parameters.required_status_checks[]?.context]|.[]')
[ -n "$uncovered" ] && echo "ABORT — would drop: $uncovered" || gh api -X DELETE "repos/$ORG/$repo/rulesets/$lid"
```

## 4. Verify

```bash
# Re-run the audit; expect zero findings in the `rulesets` category.
DRY_RUN=true CREATE_ISSUES=false bash scripts/compliance-audit.sh
```

## 5. Rollback (if needed)

```bash
# Restore an updated ruleset from its snapshot:
gh api -X PUT "repos/$ORG/<repo>/rulesets/<id>" --input "$SNAP/<repo>__<id>.json"

# Recreate a deleted ruleset (strip server-only fields first):
jq '{name,target,enforcement,conditions,rules,bypass_actors}' "$SNAP/<repo>__<id>.json" \
  | gh api -X POST "repos/$ORG/<repo>/rulesets" --input -
```

---

## Reference: 2026-06-10 fleet remediation

First full application of this runbook. Re-audit afterward reported **zero
ruleset findings** across all 8 repos.

- **Bypass actors normalized** on every default-branch ruleset (`OrganizationAdmin`
  and dependabot app, both `always`). `.github-private` was already compliant.
- **Legacy rulesets retired:** `.github/protect-branches`,
  `bmad-bgreat-suite/protect-branches`, `TalkTerm/main`, and
  `google-app-scripts/protect-branches` (after migrating its `coverage` check
  into `code-quality`).

### Known follow-up

`.github/pr-quality` non-canonically carries required status checks (Lint,
ShellCheck, Agent Security Scan). Deleting `.github/protect-branches` was safe
because those checks survive in `pr-quality` — but running `apply-rulesets.sh`
against `.github` would replace `pr-quality` with the canonical (no-checks)
version while `.github/code-quality` lacks ShellCheck / Agent Security Scan.
Reconcile `.github/code-quality`'s check set before canonicalizing
`.github/pr-quality`.
