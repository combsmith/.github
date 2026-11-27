#!/usr/bin/env bash
# nosonar-markers.sh — shared checker for inline SonarCloud suppression markers.
#
# Enforces the marker rule of the SonarCloud suppression ADR
# (docs/initiatives/sonarcloud-suppression-adr.md, #1613). The syntax table
# and examples live in the ADR and in standards/ci-standards.md; this header
# avoids spelling the keyword out, because comment text that contains it is
# itself read as a suppression by SonarCloud's IaC analyzer.
#
# An inline suppression marker is valid only when it
#   1. names a rule inside parentheses (the bare keyword is not allowed),
#   2. uses the rule-key syntax the analyzer accepts:
#        GitHub Actions / IaC YAML  analyzer-prefixed key, githubactions:S7637
#        Python                     bare rule ID, S4721
#        other languages            S1234 or repo:S1234
#   3. is followed by a reason (whitespace, then text).
# For Python the marker must also open the comment: sonar-python only reads the
# keyword at the start of a comment, and ignores any rule key that is not
# alphanumeric, so a python:S4721 key silently suppresses nothing.
#
# A "marker" is any COMMENT containing the keyword. Text in strings is not a
# comment and is ignored, so code that greps for markers is not flagged. The
# comment finder is a per-line heuristic (quote-aware, block-comment-aware for
# C-style languages); files whose extension is not listed below are not scanned.
#
# Sourced by scripts/check-nosonar-markers.sh (the PR-time CI gate) and by
# scripts/compliance-audit.sh (the org-wide sweep), so both apply one rule.
#
# Public functions:
#   nosonar_comment_style <path>          echo shell|yaml|python|hash|slash, or
#                                         nothing when the file is not scanned
#   nosonar_scan_content <path> <content> echo one "<path>:<line>: <message>"
#                                         per invalid marker; always returns 0
#   nosonar_scan_file <path>              same, reading the file from disk
#   nosonar_issue_ignore_lines <content>  echo "<line>: <key>" for each
#                                         sonar.issue.ignore.* key in a
#                                         sonar-project.properties body

nosonar_comment_style() {
  local base="${1##*/}"
  case "$base" in
    Dockerfile | *.dockerfile) echo hash; return 0 ;;
  esac
  case "${base##*.}" in
    sh | bash | zsh | ksh) echo shell ;;
    yml | yaml) echo yaml ;;
    py | pyi) echo python ;;
    rb | tf | hcl | r | R) echo hash ;;
    js | mjs | cjs | jsx | ts | mts | cts | tsx | java | kt | kts | go | c | h | cc | cpp | hpp | cs | swift | scala | php | groovy | rs | dart | css | scss | less) echo slash ;;
    *) ;;
  esac
}

nosonar_scan_content() {
  local path="$1" content="$2" style
  style=$(nosonar_comment_style "$path")
  [[ -z "$style" ]] && return 0
  # Cheap pre-filter: most files never mention the word.
  [[ "$content" == *NOSONAR* ]] || return 0
  printf '%s\n' "$content" | awk -v path="$path" -v style="$style" '
    function report(msg) { printf "%s:%d: %s\n", path, NR, msg }

    function check(cmt,    pos, rest, keys, n, i, k, inner) {
      if (index(cmt, "NOSONAR") == 0) return
      if (style == "python" && cmt !~ /^#[ \t]*NOSONAR/) {
        report("NOSONAR must open the comment in Python (sonar-python ignores it anywhere else)")
        return
      }
      if (!match(cmt, /NOSONAR\([^)]*\)/)) {
        report("bare NOSONAR: name the rule, e.g. NOSONAR(" (style == "python" ? "S1234" : style == "yaml" ? "githubactions:S1234" : "S1234") ") <reason>")
        return
      }
      inner = substr(cmt, RSTART + 8, RLENGTH - 9)
      rest = substr(cmt, RSTART + RLENGTH)
      n = split(inner, keys, ",")
      if (n == 0) { report("bare NOSONAR(): name the rule inside the parentheses"); return }
      for (i = 1; i <= n; i++) {
        k = keys[i]; gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k == "") { report("empty rule key in NOSONAR(" inner ")"); return }
        if (style == "python") {
          if (k !~ /^[A-Za-z0-9]+$/) { report("Python rule keys are bare IDs: use NOSONAR(S1234), not NOSONAR(" k ") (sonar-python ignores an invalid key)"); return }
        } else if (style == "yaml") {
          if (k !~ /^[A-Za-z0-9_-]+:[A-Za-z0-9]+$/) { report("YAML rule keys need the analyzer prefix: NOSONAR(githubactions:S1234), not NOSONAR(" k ")"); return }
        } else if (k !~ /^([A-Za-z0-9_-]+:)?[A-Za-z0-9]+$/) {
          report("invalid rule key \"" k "\" in NOSONAR(" inner ")"); return
        }
      }
      sub(/\*\/.*$/, "", rest)
      # Outside Python a marker quoted in prose (`# NOSONAR(x:S1)` marker ...) is
      # read the same way, so closing quote/backtick characters may come first.
      if (style != "python") sub(/^[`\047"]+/, "", rest)
      if (rest !~ /^[ \t]/ || rest !~ /[A-Za-z0-9]/) {
        report("NOSONAR(" inner ") needs a reason after it, e.g. NOSONAR(" inner ") <why this is safe>")
      }
    }

    BEGIN { in_block = 0 }
    {
      line = $0; len = length(line); q = ""; i = 1
      if (in_block) {
        e = index(line, "*/")
        if (e == 0) { check(line); next }
        check(substr(line, 1, e - 1)); in_block = 0; i = e + 2
      }
      for (; i <= len; i++) {
        c = substr(line, i, 1)
        p = (i > 1) ? substr(line, i - 1, 1) : ""
        if (q != "") {
          if (c == "\\" && !(style == "shell" && q == "\047")) { i++; continue }
          if (c == q) q = ""
          continue
        }
        if (c == "\"" || c == "\047" || (style == "slash" && c == "`")) {
          # A YAML quote only opens a scalar at a token start; mid-word it is text.
          if (style == "yaml" && i > 1 && p !~ /[ \t:\[{,-]/) continue
          q = c; continue
        }
        if (style == "slash") {
          two = substr(line, i, 2)
          if (two == "//") { check(substr(line, i)); break }
          if (two == "/*") {
            e = index(substr(line, i + 2), "*/")
            if (e == 0) { check(substr(line, i)); in_block = 1; break }
            check(substr(line, i, e + 3)); i = i + e + 2; continue
          }
        } else if (c == "#" && (style == "python" || i == 1 || p ~ /[ \t]/)) {
          check(substr(line, i)); break
        }
      }
    }
  '
  return 0
}

nosonar_scan_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  [[ -n "$(nosonar_comment_style "$path")" ]] || return 0
  nosonar_scan_content "$path" "$(cat "$path")"
}

nosonar_issue_ignore_lines() {
  printf '%s\n' "$1" | awk '
    /^[ \t]*[#!]/ { next }
    match($0, /^[ \t]*sonar\.issue\.ignore\.[^= \t:]*/) {
      k = substr($0, RSTART, RLENGTH); sub(/^[ \t]+/, "", k)
      printf "%d: %s\n", NR, k
    }
  '
}
