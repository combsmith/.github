#!/usr/bin/env bats
# Tests for the workflow-level concurrency group of the feature-ideation caller
# stub (#1576).
#
# The Discussion bridge (`redispatch`) dispatches an analyst run and then polls
# for it to post the run link on the Idea. GitHub keeps one pending run per
# concurrency group, so a bridge that shares the analysts' group can get the
# analyst run it just dispatched replaced and cancelled. The bridge must
# therefore never occupy the analyst group, and two bridges must not share a
# group either (a third Idea would cancel the second Idea's pending bridge).
#
# STATIC: parses the stubs and evaluates `concurrency.group` with a small model
# of GitHub expressions (`==`, `&&`, `||`, `format`, string literals and the
# contexts listed below). Any other term is refused, so a rewritten group fails
# here until the model is taught.

load 'helpers/setup'

TEMPLATE="${TT_REPO_ROOT}/standards/workflows/feature-ideation.yml"
SELF_STUB="${TT_REPO_ROOT}/.github/workflows/feature-ideation.yml"

# group <stub> <event_name> <run_id>: prints the evaluated concurrency group.
group() {
  python3 - "$@" <<'PYEOF'
import ast, re, sys, yaml

path, event_name, run_id = sys.argv[1:4]
raw = yaml.safe_load(open(path))["concurrency"]["group"]

def fmt(template, *args):
    return re.sub(r"\{(\d+)\}", lambda m: str(args[int(m.group(1))]), template)

def evaluate(expr):
    py = (expr.replace("&&", " and ").replace("||", " or ")
              .replace("github.event_name", "event_name")
              .replace("github.run_id", "run_id"))
    tree = ast.parse(py.strip(), mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.Compare, ast.Eq,
               ast.Constant, ast.Name, ast.Load, ast.Call)
    for node in ast.walk(tree):
        if not isinstance(node, allowed):
            sys.stderr.write(f"group model does not know: {ast.dump(node)}\n")
            sys.exit(3)
        if isinstance(node, ast.Name) and node.id not in ("event_name", "run_id", "format"):
            sys.stderr.write(f"group model does not know: {node.id}\n")
            sys.exit(3)
    return eval(compile(tree, path, "eval"),
                {"__builtins__": {}},
                {"event_name": event_name, "run_id": run_id, "format": fmt})

out = re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(evaluate(m.group(1))), str(raw))
print(out)
PYEOF
}

@test "concurrency: analyst runs (schedule, workflow_dispatch) share the feature-ideation group" {
  for stub in "$TEMPLATE" "$SELF_STUB"; do
    [ "$(group "$stub" schedule 1)" = "feature-ideation" ]
    [ "$(group "$stub" workflow_dispatch 2)" = "feature-ideation" ]
  done
}

@test "concurrency: analyst runs serialize and are never cancelled in progress" {
  for stub in "$TEMPLATE" "$SELF_STUB"; do
    [ "$(yq -r '.concurrency."cancel-in-progress"' "$stub")" = "false" ]
  done
}

@test "concurrency: the discussion bridge never occupies the analyst group" {
  for stub in "$TEMPLATE" "$SELF_STUB"; do
    run group "$stub" discussion 7
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "$(group "$stub" workflow_dispatch 7)" ]
    [ "$output" != "$(group "$stub" schedule 7)" ]
  done
}

@test "concurrency: each bridge run gets its own group, so one Idea's bridge cannot cancel another's" {
  for stub in "$TEMPLATE" "$SELF_STUB"; do
    [ "$(group "$stub" discussion 7)" != "$(group "$stub" discussion 8)" ]
  done
}

@test "concurrency: no job-level concurrency puts the bridge back in a shared group" {
  for stub in "$TEMPLATE" "$SELF_STUB"; do
    [ "$(yq -r '.jobs.redispatch.concurrency // "none"' "$stub")" = "none" ]
  done
}

@test "concurrency: both stubs carry the same concurrency block" {
  [ "$(yq -o=json -I=0 '.concurrency' "$TEMPLATE")" = "$(yq -o=json -I=0 '.concurrency' "$SELF_STUB")" ]
}
