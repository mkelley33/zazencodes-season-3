#!/usr/bin/env bash
#
# Drift test for the software factory's two descriptions of itself:
# BUILD_PROMPT.md (the shape) and SKILL.md (the procedure). Both must name
# every stage label and every command.
#
# Run: bash scripts/docs.test.sh
#
# Written for bash 3.2 (the macOS default).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../src/software-factory-claude-code"
FILES="BUILD_PROMPT.md .claude/skills/factory/SKILL.md"

case_count=0
failure_count=0

fail() {
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n' "$1"
}

# Asserts that the string $1 appears in both files.
check() {
  case_count=$((case_count + 1))
  for file in $FILES; do
    grep -qF -- "$1" "$TEMPLATE/$file" || fail "'$1' is missing from $file"
  done
}

# The six stage labels.
check "factory:spec"
check "factory:build"
check "factory:review"
check "factory:approve"
check "factory:pr"
check "factory:needs-human"

# The five commands.
check "/factory <feature>"
check "/factory next"
check "/factory approve"
check "/factory rework"
check "/factory clean"

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
