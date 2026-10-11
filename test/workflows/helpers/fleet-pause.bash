#!/usr/bin/env bash
# Fleet-pause (AGENTS_PAUSED) helpers, shared by the suites that check the
# pause gate of a workflow that calls a model:
#   test/workflows/feature-ideation/fleet-pause.bats   (#1295)
#   test/workflows/compliance-audit/fleet-pause.bats   (#1309)
#
# Use: `load '../helpers/fleet-pause'`, set WF to the workflow under test and
# call `fp_setup` from `setup`.
#
# One evaluator for every suite, so the model of GitHub's expression rules
# cannot drift between them. It stays a heredoc written to the test's temp
# directory, not a .py file in the tree: sonar-project.properties sets no
# sonar.sources, sonar.tests or exclusions, so SonarCloud would count a
# committed .py as Python source with no coverage behind it.

# Repo root, regardless of where bats is invoked from.
FP_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
export FP_REPO_ROOT

# fp_setup — write the evaluator to $PAUSE_PY. Call it from `setup`.
fp_setup() {
  # PyYAML parses the workflow. Without it the suite FAILS, here and in CI: a
  # skip would report the gate as checked when nothing looked at it. The CI
  # jobs install it from scripts/feature-ideation-tests-requirements.txt;
  # locally:
  #   python3 -m pip install -r scripts/feature-ideation-tests-requirements.txt
  if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "PyYAML is required: python3 -m pip install -r scripts/feature-ideation-tests-requirements.txt" >&2
    return 1
  fi
  PAUSE_PY="${BATS_TEST_TMPDIR}/pause.py"
  cat > "$PAUSE_PY" <<'PY'
"""Read the pause gate of a workflow file. Usage: pause.py <workflow> <command>

  gate <job>   exit 0 when the job's `if:` opens with the pause gate and nothing
               after it can bypass the pause; else print why and exit 1
  if <job>     the job's `if:` on one line (empty when it has none)
  jobs         every job id, one per line
  model-jobs   the ids of the jobs that can reach a model
  table [<job>=<result> ...]
               <job> TAB <value label> TAB runs|skipped, for every job and
               value. A job a row's job needs ended in `success` unless its
               result (success, failure, cancelled or skipped) is given.
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
# How a job a job needs can end (`needs.<job>.result`).
RESULTS = ("success", "failure", "cancelled", "skipped")
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
    r"|(?P<lit>(?:true|false)\b)|(?P<fn>[A-Za-z_]\w*\s*\(\s*\))"
    r"|(?P<ctx>[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)+))")
NEEDS_RESULT = re.compile(r"needs\.([A-Za-z_][\w-]*)\.result")


class Unsupported(Exception):
    pass


def norm_if(value):
    """An `if:` as one line: no `${{ }}` wrapper, single spaces."""
    text = "" if value is None else str(value).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return " ".join(text.split())


def needs_of(job):
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


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
    """`||`, `&&`, `==`, `!=`, `!`, parentheses, string literals, `vars.*`,
    `always()` and `needs.<job>.result`: the subset a pause gate and the job
    conditions beside it need. Anything else raises Unsupported."""

    def __init__(self, expr, variables, needs):
        self.toks, self.i, self.vars, self.needs = tokens(expr), 0, variables, needs

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
        if kind == "fn" and text.split("(")[0].strip() == "always":
            return True
        if kind == "ctx" and text.startswith("vars."):
            # An unset configuration variable reads as the empty string.
            return self.vars.get(text[len("vars."):], "")
        if kind == "ctx" and text.startswith("needs."):
            m = NEEDS_RESULT.fullmatch(text)
            if not m or m.group(1) not in self.needs:
                raise Unsupported(f"`{text}` is not the result of a job this one needs")
            return self.needs[m.group(1)]
        raise Unsupported(f"`{text}` is outside the pause-gate subset")


def runs(job, value, results):
    expr = norm_if(job.get("if"))
    variables = {} if value is None else {"AGENTS_PAUSED": value}
    needs = {dep: results.get(dep, "success") for dep in needs_of(job)}
    wanted = truthy(Parser(expr, variables, needs).parse()) if expr else True
    # GitHub puts an implied `success() &&` in front of an `if:` that names no
    # status-check function, and looks for one anywhere in the expression, not
    # only at its start (actions/runner, ConvertToIfCondition:
    # `node.Traverse().Any`). `always()` is the only one the parser accepts;
    # without it a dependency that did not succeed skips the job.
    has_status_function = any(kind == "fn" for kind, _ in tokens(expr))
    if not has_status_function and any(r != "success" for r in needs.values()):
        return False
    return wanted


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
    elif command == "if":
        job = jobs.get(sys.argv[3])
        if not isinstance(job, dict):
            print(f"the workflow has no job '{sys.argv[3]}'")
            return 1
        print(norm_if(job.get("if")))
    elif command == "jobs":
        print("\n".join(jobs))
    elif command == "model-jobs":
        print("\n".join(j for j, body in jobs.items() if SIGNALS.search(yaml.safe_dump(body))))
    elif command == "table":
        results = {}
        for arg in sys.argv[3:]:
            dep, _, result = arg.partition("=")
            if dep not in jobs or result not in RESULTS:
                print(f"`{arg}` is not <job>=<{'|'.join(RESULTS)}>")
                return 2
            results[dep] = result
        for job_id, job in jobs.items():
            for label, value in PAUSE_VALUES:
                print(f"{job_id}\t{label}\t{'runs' if runs(job, value, results) else 'skipped'}")
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
        print(f"workflow_permissions={doc.get('permissions')!r}")
        print(f"shell_only={all('uses' not in s for s in steps)}")
        print(f"secret_refs={bool(SECRET_REF.search(text)) or 'secrets' in notice}")
        print(f"model_signal={bool(SIGNALS.search(text))}")
        print(f"expression_in_run={'${{' in scripts}")
        print(f"env_source={(notice.get('env') or {}).get('PAUSE_SOURCE')}")
        print(f"env_until={(notice.get('env') or {}).get('PAUSE_UNTIL')}")
        for job_id, body in jobs.items():
            print(f"needs.{job_id}=" + ",".join(needs_of(body)))
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

# pause <command> [args] — run the evaluator on $WF; read $status and $output.
pause() { run python3 "$PAUSE_PY" "$WF" "$@"; }

# load_table [<job>=<result> ...] — keep `pause table` in $TABLE for `outcome`.
load_table() {
  pause table "$@"
  # shellcheck disable=SC2154  # bats' `run` sets status and output
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  TABLE="$output"
}

# outcome <job> <value label> — `runs` or `skipped`, from the last `load_table`.
outcome() {
  awk -F'\t' -v job="$1" -v value="$2" '$1 == job && $2 == value { print $3 }' <<< "$TABLE"
}
