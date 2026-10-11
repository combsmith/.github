#!/usr/bin/env bats
# Fleet pause gate of the reusable feature-ideation workflow (#1295).
#
# `AGENTS_PAUSED=true` is the Actions variable that pauses the agent fleet
# (petry-projects/.github-private#1525, #2249). The caller stubs are frozen, so
# the gate lives in feature-ideation-reusable.yml: every job but the notice
# carries `vars.AGENTS_PAUSED != 'true'`, and `fleet-paused` says why on the
# complementary condition. The rule mirrors .github-private: only the word
# `true` pauses, in any letter case (GitHub compares strings without regard to
# case); unset, `false`, `1` or a padded value run the workflow as before.
#
# What this suite proves, and what it cannot:
#   - It is STATIC. It parses the workflow file and evaluates each job's `if:`
#     with a small model of GitHub's expression rules (an unset variable is the
#     empty string, string equality ignores case). The model refuses anything
#     it does not know, so a rewritten gate fails here until the test is taught.
#   - It EXECUTES the notice step's script, so the line it prints is real.
#   - It does NOT prove that GitHub hands the calling repository's (or the
#     organisation's) variables to a `workflow_call` job, nor that a paused run
#     ends green. Only a live run with the variable set can.
#
# Run: bats test/workflows/feature-ideation/fleet-pause.bats   (needs python3 + PyYAML)

load 'helpers/setup'

WF="${TT_REPO_ROOT}/.github/workflows/feature-ideation-reusable.yml"

setup() {
  # PyYAML parses the workflow: skip locally without it, never silently in CI
  # (feature-ideation-tests.yml installs it from
  # scripts/feature-ideation-tests-requirements.txt).
  if ! python3 -c 'import yaml' 2>/dev/null; then
    if [ -n "${CI:-}" ]; then
      echo "PyYAML is required in CI" >&2
      return 1
    fi
    skip "PyYAML not installed"
  fi
  PAUSE_PY="${BATS_TEST_TMPDIR}/pause.py"
  cat > "$PAUSE_PY" <<'PY'
"""Read the pause gate of a workflow file. Usage: pause.py <workflow> <command>

  gate <job>   exit 0 when the job's `if:` opens with the pause gate and nothing
               after it can bypass the pause; else print why and exit 1
  jobs         every job id, one per line
  model-jobs   the ids of the jobs that can reach a model
  table        <job> TAB <value label> TAB runs|skipped, for every job and value
  notice       facts about the `fleet-paused` job, one `key=value` per line
  notice-run   the `run:` script of the notice step
"""
import re
import sys

import yaml

GATE = "vars.AGENTS_PAUSED != 'true'"
NOTICE_JOB = "fleet-paused"
# The values a maintainer or the budget breaker can leave in the variable.
PAUSE_VALUES = (
    ("unset", None), ("false", "false"), ("true", "true"), ("TRUE", "TRUE"),
    ("True", "True"), ("1", "1"), ("yes", "yes"), ("padded", " true "),
)
# How a job reaches a model: a model credential, an AI CLI or action, a model
# CLI call or a model API host. The same list .github-private checks.
SIGNALS = re.compile(
    r"CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY"
    r"|COPILOT_GITHUB_TOKEN|OPENAI_API_KEY"
    r"|@anthropic-ai/claude-code|@google/gemini-cli|anthropics/claude-code-action"
    r"|claude\s+(?:-p\b|--print\b)|gemini\s+(?:-p\b|--prompt\b|-m\b)"
    r"|gh[ -]copilot|gh models"
    r"|api\.anthropic\.com|generativelanguage\.googleapis\.com|api\.openai\.com"
    r"|models\.github\.ai|models\.inference\.ai\.azure\.com")
SECRET_REF = re.compile(r"\bsecrets\s*[.\[]|\bgithub\.token\b", re.I)

TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<op>==|!=|&&|\|\||!|\(|\))"
    r"|(?P<lit>(?:true|false)\b)|(?P<ctx>[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)+))")


class Unsupported(Exception):
    pass


def norm_if(value):
    """An `if:` as one line: no `${{ }}` wrapper, single spaces."""
    text = "" if value is None else str(value).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return " ".join(text.split())


def tokens(expr):
    out, pos = [], 0
    while pos < len(expr):
        if expr[pos:].strip() == "":
            break
        m = TOKEN.match(expr, pos)
        if not m:
            raise Unsupported(f"cannot read `{expr[pos:]}`")
        out.append((m.lastgroup, m.group(m.lastgroup)))
        pos = m.end()
    return out


def truthy(value):
    return value if isinstance(value, bool) else value != ""


class Parser:
    """`||`, `&&`, `==`, `!=`, `!`, parentheses, string literals and `vars.*`:
    the subset a pause gate needs. Anything else raises Unsupported."""

    def __init__(self, expr, variables):
        self.toks, self.i, self.vars = tokens(expr), 0, variables

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def parse(self):
        value = self.either()
        if self.i != len(self.toks):
            raise Unsupported(f"unexpected `{self.peek()[1]}`")
        return value

    def either(self):
        left = self.both()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.both()
            left = left if truthy(left) else right
        return left

    def both(self):
        left = self.equal()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.equal()
            left = right if truthy(left) else left
        return left

    def equal(self):
        left = self.unary()
        if self.peek() in (("op", "=="), ("op", "!=")):
            op = self.take()[1]
            right = self.unary()
            if type(left) is not type(right):
                raise Unsupported("comparison of a string with a boolean")
            # GitHub ignores case when it compares strings.
            same = left.lower() == right.lower() if isinstance(left, str) else left == right
            return same if op == "==" else not same
        return left

    def unary(self):
        kind, text = self.take()
        if (kind, text) == ("op", "!"):
            return not truthy(self.unary())
        if (kind, text) == ("op", "("):
            value = self.either()
            if self.take() != ("op", ")"):
                raise Unsupported("unbalanced parentheses")
            return value
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind == "lit":
            return text == "true"
        if kind == "ctx" and text.startswith("vars."):
            # An unset configuration variable reads as the empty string.
            return self.vars.get(text[len("vars."):], "")
        raise Unsupported(f"`{text}` is outside the pause-gate subset")


def runs(job, value):
    expr = norm_if(job.get("if"))
    if not expr:
        return True
    variables = {} if value is None else {"AGENTS_PAUSED": value}
    return truthy(Parser(expr, variables).parse())


def has_top_level_or(expr):
    depth, in_str, i = 0, False, 0
    while i < len(expr):
        ch = expr[i]
        if in_str:
            if ch == "'":
                if expr[i + 1:i + 2] == "'":
                    i += 1
                else:
                    in_str = False
        elif ch == "'":
            in_str = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif expr[i:i + 2] == "||" and depth == 0:
            return True
        i += 1
    return False


def gate_problem(job):
    """Why the job is not safely gated, or '' when it is: the gate is the first
    term and only `&&` terms follow (`&&` binds tighter than `||`, so
    `gate && a || b` would run on `b` whatever the variable says)."""
    expr = norm_if(job.get("if"))
    if expr == GATE:
        return ""
    if not expr.startswith(GATE + " && "):
        return f"its `if:` must start with `{GATE}` (found `{expr or 'no if:'}`)"
    if has_top_level_or(expr[len(GATE) + 4:]):
        return f"its `if:` has a top-level `||` after `{GATE} &&`"
    return ""


def main():
    path, command = sys.argv[1], sys.argv[2]
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    jobs = doc.get("jobs") or {}
    if command == "gate":
        job = jobs.get(sys.argv[3])
        why = "the workflow has no such job" if not isinstance(job, dict) else gate_problem(job)
        if why:
            print(f"job '{sys.argv[3]}' is not paused by AGENTS_PAUSED: {why}")
            return 1
    elif command == "jobs":
        print("\n".join(jobs))
    elif command == "model-jobs":
        print("\n".join(j for j, body in jobs.items() if SIGNALS.search(yaml.safe_dump(body))))
    elif command == "table":
        for job_id, job in jobs.items():
            for label, value in PAUSE_VALUES:
                print(f"{job_id}\t{label}\t{'runs' if runs(job, value) else 'skipped'}")
    elif command in ("notice", "notice-run"):
        notice = jobs.get(NOTICE_JOB)
        if not isinstance(notice, dict):
            print(f"the workflow has no `{NOTICE_JOB}` job")
            return 1
        steps = notice.get("steps") or []
        if command == "notice-run":
            if len(steps) != 1 or "run" not in steps[0]:
                print(f"`{NOTICE_JOB}` must be one `run:` step")
                return 1
            print(steps[0]["run"])
            return 0
        text = yaml.safe_dump(notice)
        scripts = "\n".join(str(s.get("run", "")) for s in steps)
        on = doc.get(True) or doc.get("on") or {}
        print(f"if={norm_if(notice.get('if'))}")
        print(f"standalone={'needs' not in notice and 'uses' not in notice}")
        print(f"permissions={notice.get('permissions')!r}")
        print(f"shell_only={all('uses' not in s for s in steps)}")
        print(f"secret_refs={bool(SECRET_REF.search(text)) or 'secrets' in notice}")
        print(f"model_signal={bool(SIGNALS.search(text))}")
        print(f"expression_in_run={'${{' in scripts}")
        print(f"env_source={(notice.get('env') or {}).get('PAUSE_SOURCE')}")
        print(f"env_until={(notice.get('env') or {}).get('PAUSE_UNTIL')}")
        for job_id, body in jobs.items():
            needs = body.get("needs") or []
            print(f"needs.{job_id}=" + ",".join([needs] if isinstance(needs, str) else needs))
        print("workflow_outputs=" + ",".join((on.get("workflow_call") or {}).get("outputs") or {}))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Unsupported as exc:
        print(f"unsupported `if:` expression: {exc}")
        sys.exit(3)
PY
}

pause() { run python3 "$PAUSE_PY" "$WF" "$@"; }

# outcome <job> <value label> — `runs` or `skipped`, from the last `pause table`.
outcome() {
  awk -F'\t' -v job="$1" -v value="$2" '$1 == job && $2 == value { print $3 }' <<< "$TABLE"
}

load_table() {
  pause table
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  TABLE="$output"
}

# ── the gate ─────────────────────────────────────────────────────────────────

@test "pause gate: analyze is the job that reaches the model, and it is gated" {
  pause model-jobs
  [ "$status" -eq 0 ]
  [ "$output" = "analyze" ]
  pause gate analyze
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pause gate: every job but the notice is gated, so a paused run starts nothing else" {
  pause jobs
  [ "$status" -eq 0 ]
  local job n=0
  local -a jobs=()
  while IFS= read -r job; do jobs+=("$job"); done <<< "$output"
  for job in "${jobs[@]}"; do
    [ "$job" = "fleet-paused" ] && continue
    pause gate "$job"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    n=$((n + 1))
  done
  # gather-signals only feeds analyze; skipping it too leaves no orphan artifact.
  [ "$n" -eq 2 ]
  [[ " ${jobs[*]} " == *" gather-signals "* ]]
  [[ " ${jobs[*]} " == *" analyze "* ]]
}

# ── skipped when true, runs when unset or false (acceptance criterion 1) ─────

@test "truth table: analyze is skipped when AGENTS_PAUSED is true, and runs when it is unset or false" {
  load_table
  [ "$(outcome analyze true)" = "skipped" ]
  [ "$(outcome analyze unset)" = "runs" ]
  [ "$(outcome analyze false)" = "runs" ]
}

@test "truth table: gather-signals follows analyze for every value" {
  load_table
  local value
  for value in unset false true TRUE True 1 yes padded; do
    [ -n "$(outcome analyze "$value")" ] || { echo "no row for analyze/$value"; return 1; }
    [ "$(outcome gather-signals "$value")" = "$(outcome analyze "$value")" ] || {
      echo "gather-signals and analyze differ for AGENTS_PAUSED=$value"; return 1; }
  done
}

@test "truth table: only the word true pauses, in any letter case" {
  load_table
  local value
  for value in TRUE True; do
    [ "$(outcome analyze "$value")" = "skipped" ] || { echo "AGENTS_PAUSED=$value did not pause"; return 1; }
  done
  for value in 1 yes padded; do
    [ "$(outcome analyze "$value")" = "runs" ] || { echo "AGENTS_PAUSED=$value paused"; return 1; }
  done
}

@test "truth table: fleet-paused is the exact complement of analyze" {
  load_table
  local value want
  for value in unset false true TRUE True 1 yes padded; do
    if [ "$(outcome analyze "$value")" = "skipped" ]; then want=runs; else want=skipped; fi
    [ "$(outcome fleet-paused "$value")" = "$want" ] || {
      echo "fleet-paused AGENTS_PAUSED=$value: $(outcome fleet-paused "$value"), want $want"; return 1; }
  done
}

# ── the notice job: what a paused run does instead ───────────────────────────

@test "notice job: stands alone, and no job or workflow output waits on a skipped job" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"if=vars.AGENTS_PAUSED == 'true'"* ]]
  [[ "$output" == *"standalone=True"* ]]
  # Nothing reads a result the paused run does not produce: analyze waits on
  # gather-signals (both skipped), and no job waits on analyze or the notice.
  grep -qx "needs.gather-signals=" <<< "$output"
  grep -qx "needs.analyze=gather-signals" <<< "$output"
  grep -qx "needs.fleet-paused=" <<< "$output"
  [ "$(grep -c '^needs\.' <<< "$output")" -eq 3 ]
  grep -qx "workflow_outputs=" <<< "$output"
}

@test "notice job: it runs while paused, so it holds no secret, token, action or permission" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "permissions={}" <<< "$output"
  grep -qx "shell_only=True" <<< "$output"
  grep -qx "secret_refs=False" <<< "$output"
  grep -qx "model_signal=False" <<< "$output"
}

@test "notice job: the pause variables reach the script through env, never \${{ }} in run:" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF 'env_source=${{ vars.AGENTS_PAUSE_SOURCE }}' <<< "$output"
  grep -qxF 'env_until=${{ vars.AGENTS_PAUSE_UNTIL }}' <<< "$output"
  grep -qx "expression_in_run=False" <<< "$output"
}

@test "notice: prints one ::notice line naming the pause source and until time" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE=rate-limit-observed PAUSE_UNTIL=2026-10-13T16:00:00Z run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "::notice title=Agent fleet paused::Feature Ideation: not run, the agent fleet is paused (AGENTS_PAUSED=true)."* ]]
  [[ "$output" == *" Pause source: rate-limit-observed. Paused until: 2026-10-13T16:00:00Z." ]]
}

@test "notice: an unset source and until time read as not set (a pause set by hand)" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE='' PAUSE_UNTIL='' run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *" Pause source: not set (paused by hand). Paused until: not set." ]]
}

@test "notice: a line break in a value cannot start a second workflow command" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE=$'by hand\n::error title=injected::boom' PAUSE_UNTIL=$'soon\r\n::stop-commands::x' \
    run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "::notice title=Agent fleet paused::"* ]]
  # The hostile text is still there, as data inside the one notice.
  [[ "$output" == *"Pause source: by hand ::error title=injected::boom."* ]]
  [[ "$output" != *$'\r'* ]]
}
