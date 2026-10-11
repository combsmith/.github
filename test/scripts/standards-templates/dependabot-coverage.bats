#!/usr/bin/env bats
# Guard: Dependabot's `github-actions` updates cover every directory of published
# workflow YAML (#1172).
#
# `directory: "/"` makes Dependabot scan `.github/workflows/` only. The templates
# under `standards/workflows/` are what every consumer is seeded from and
# drift-checked against, so pins there went stale while consumers moved ahead and
# then read as drifted. Each directory under `standards/` that holds workflow YAML
# therefore needs its own `github-actions` entry in `.github/dependabot.yml`.
#
# A directory "holds workflow YAML" when a `*.yml` / `*.yaml` file directly inside
# it has a top-level `jobs:` key. Dependabot config files and JSON data do not.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
: "${DEPENDABOT_CONFIG:=${REPO_ROOT}/.github/dependabot.yml}"
: "${STANDARDS_DIR:=${REPO_ROOT}/standards}"

# actions_entries — one "<directory>\t<ignored dependency names, comma-joined>"
# line per directory a `github-actions` update entry covers. Reads both the
# `directory:` scalar and the `directories:` list (inline or block form). Only a
# `dependency-name` inside the entry's `ignore:` block counts as ignored: the same
# key under `allow:` means the opposite.
actions_entries() {
  awk '
    # value(s) — a YAML scalar without its quotes or a trailing "# comment".
    function value(s,   q) {
      sub(/^[ \t]+/, "", s)
      q = substr(s, 1, 1)
      if (q == "\"" || q == "\047") {
        s = substr(s, 2)
        if (index(s, q) > 0) s = substr(s, 1, index(s, q) - 1)
        return s
      }
      sub(/[ \t]+#.*$/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    function flush(   i) {
      if (eco == "github-actions") for (i = 1; i <= nd; i++) printf "%s\t%s\n", dirs[i], ign
      eco = ""; nd = 0; ign = ""; sect = ""
    }
    /^[ \t]*#/ { next }
    /^[ \t]*-[ \t]*package-ecosystem:/ {
      flush(); s = $0; sub(/.*package-ecosystem:/, "", s); eco = value(s)
      # The column where the keys of this entry start ("- " included).
      match($0, /^[ \t]*-[ \t]*/); keycol = RLENGTH
      next
    }
    /^[ \t]*directory:/ { s = $0; sub(/.*directory:/, "", s); dirs[++nd] = value(s); sect = ""; next }
    /^[ \t]*directories:/ {
      s = $0; sub(/.*directories:/, "", s); sub(/[ \t]+#.*$/, "", s)
      if (s ~ /\[/) {
        gsub(/[\[\]]/, "", s); n = split(s, parts, ",")
        for (i = 1; i <= n; i++) if (value(parts[i]) != "") dirs[++nd] = value(parts[i])
        sect = ""
      } else sect = "directories"
      next
    }
    sect == "directories" && /^[ \t]*-[ \t]*[^ \t]/ && $0 !~ /^[ \t]*-[ \t]*[A-Za-z-]+:/ {
      s = $0; sub(/^[ \t]*-/, "", s); dirs[++nd] = value(s); next
    }
    /^[ \t]*-[ \t]*dependency-name:/ {
      if (sect == "ignore") { s = $0; sub(/.*dependency-name:/, "", s); ign = (ign == "" ? "" : ign ",") value(s) }
      next
    }
    # Another key AT ENTRY LEVEL ends the current block and starts its own. A key
    # nested deeper (e.g. `versions:` under one ignore item) leaves the block open.
    /^[ \t]*[A-Za-z-]+:/ {
      match($0, /^[ \t]*/)
      if (RLENGTH == keycol) { s = $0; sub(/^[ \t]*/, "", s); sub(/:.*/, "", s); sect = s }
    }
    END { flush() }
  ' "$DEPENDABOT_CONFIG"
}

# covered_dirs — the directories alone, one per line.
covered_dirs() { actions_entries | cut -f1; }

# published_workflow_dirs — every directory under standards/ that holds workflow
# YAML, as a repo-absolute path ("/standards/workflows"), one per line.
published_workflow_dirs() {
  local f
  find "$STANDARDS_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 \
    | while IFS= read -r -d '' f; do
        if grep -qE '^jobs:' "$f"; then
          printf '/standards%s\n' "$(dirname "${f#"$STANDARDS_DIR"}")"
        fi
      done | sort -u
}

@test "the detector finds standards/workflows (so the coverage test is not vacuous)" {
  run published_workflow_dirs
  [ "$status" -eq 0 ]
  [[ $'\n'"$output"$'\n' == *$'\n/standards/workflows\n'* ]]
}

@test "github-actions updates still cover the repo root" {
  run covered_dirs
  [ "$status" -eq 0 ]
  [[ $'\n'"$output"$'\n' == *$'\n/\n'* ]]
}

@test "every directory of published workflow YAML has a github-actions entry (#1172)" {
  local covered missing=() d
  covered="$(covered_dirs)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [[ $'\n'"$covered"$'\n' == *$'\n'"$d"$'\n'* ]] || missing+=("$d")
  done < <(published_workflow_dirs)
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "No github-actions entry in .github/dependabot.yml for: ${missing[*]}"
    echo "Dependabot never bumps action pins there. Add a github-actions entry per directory."
    return 1
  fi
}

@test "every covered directory exists (no stale entry)" {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ ! -d "${REPO_ROOT}${d}" ]; then
      echo "github-actions entry points at a directory that does not exist: $d"
      return 1
    fi
  done < <(covered_dirs)
}

@test "entries for published templates leave first-party channel pins alone" {
  local dir ignored bad=()
  while IFS=$'\t' read -r dir ignored; do
    case "$dir" in
      /standards/*)
        [[ ",${ignored}," == *",petry-projects/*,"* ]] || bad+=("$dir")
        ;;
    esac
  done < <(actions_entries)
  if [ "${#bad[@]}" -gt 0 ]; then
    echo "github-actions entry must ignore petry-projects/* (channel pins are moved by release tooling): ${bad[*]}"
    return 1
  fi
}

# ── The parser, against configs it must read correctly ──────────────────────

@test "parser: reads a directory scalar, an inline directories list and a block list" {
  DEPENDABOT_CONFIG="${BATS_TEST_TMPDIR}/dependabot.yml"
  cat > "$DEPENDABOT_CONFIG" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/web"
    schedule:
      interval: "weekly"
  - package-ecosystem: 'github-actions'
    directories: ["/", "/standards/workflows"]
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directories:
      - "/standards/other"
      - /standards/third
    labels:
      - "security"
    ignore:
      - dependency-name: "petry-projects/*"
      - dependency-name: "actions/checkout"
YAML
  run actions_entries
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/\t\n/standards/workflows\t\n/standards/other\tpetry-projects/*,actions/checkout\n/standards/third\tpetry-projects/*,actions/checkout')" ]
}

@test "parser: a dependency-name under allow: is not read as ignored" {
  DEPENDABOT_CONFIG="${BATS_TEST_TMPDIR}/dependabot.yml"
  cat > "$DEPENDABOT_CONFIG" <<'YAML'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/standards/workflows"
    allow:
      - dependency-name: "petry-projects/*"
    labels:
      - "security"
  - package-ecosystem: "github-actions"
    directory: "/standards/other"
    ignore:
      - dependency-name: "petry-projects/*"
        versions: ["1.x"]
      - dependency-name: "actions/checkout"
    allow:
      - dependency-name: "actions/*"
YAML
  run actions_entries
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/standards/workflows\t\n/standards/other\tpetry-projects/*,actions/checkout')" ]
}

@test "parser: a trailing YAML comment is not part of a directory or a dependency name" {
  DEPENDABOT_CONFIG="${BATS_TEST_TMPDIR}/dependabot.yml"
  cat > "$DEPENDABOT_CONFIG" <<'YAML'
version: 2
updates:
  - package-ecosystem: "github-actions" # actions
    directory: "/standards/workflows" # the published templates
    ignore:
      - dependency-name: "petry-projects/*" # channel pins
  - package-ecosystem: github-actions
    directory: /standards/plain   # unquoted
    directories: ["/a", "/b"] # inline list
YAML
  run actions_entries
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/standards/workflows\tpetry-projects/*\n/standards/plain\t\n/a\t\n/b\t')" ]
}

@test "parser: a root-only config covers no standards directory (the #1172 state)" {
  DEPENDABOT_CONFIG="${BATS_TEST_TMPDIR}/dependabot.yml"
  cat > "$DEPENDABOT_CONFIG" <<'YAML'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    labels:
      - "security"
      - "dependencies"
YAML
  run covered_dirs
  [ "$output" = "/" ]
}

@test "detector: a new directory of workflow YAML under standards/ is found, data files are not" {
  STANDARDS_DIR="${BATS_TEST_TMPDIR}/standards"
  mkdir -p "$STANDARDS_DIR/workflows" "$STANDARDS_DIR/more/nested" "$STANDARDS_DIR/dependabot"
  printf 'name: A\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$STANDARDS_DIR/workflows/a.yml"
  printf 'name: B\non: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n' > "$STANDARDS_DIR/more/nested/b.yaml"
  printf 'version: 2\nupdates: []\n' > "$STANDARDS_DIR/dependabot/frontend.yml"
  run published_workflow_dirs
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/standards/more/nested\n/standards/workflows')" ]
}
