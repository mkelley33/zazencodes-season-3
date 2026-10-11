#!/usr/bin/env bash
#
# Drift test for the software factory's two descriptions of itself:
# BUILD_PROMPT.md (the shape) and SKILL.md (the procedure). Both must name
# every stage label and every command. Also checks the dashboard footer's
# command list, the agents' heredoc delimiter, the command that reads issue
# comments, what the README claims for the Guard, and that the README names
# every flag of the install script and of serve.py.
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

# The dashboard footer lists the five commands too.
case_count=$((case_count + 1))
for command in "/factory &lt;feature&gt;" "/factory next" "/factory approve" "/factory rework" "/factory clean"; do
  grep -qF -- "<span>$command" "$TEMPLATE/factory/dashboard.html" \
    || fail "'$command' is missing from the footer of factory/dashboard.html"
done

# Agents that post a comment from a heredoc end it with FACTORY_COMMENT, a
# line no quoted review text is likely to hold, never EOF.
case_count=$((case_count + 1))
for agent in spec-writer reviewer-security reviewer-ux reviewer-ui reviewer-code approver; do
  file=".claude/agents/$agent.md"
  grep -qF -- "--body-file - <<'FACTORY_COMMENT'" "$TEMPLATE/$file" \
    || fail "$file has no --body-file - <<'FACTORY_COMMENT' block"
  grep -qx "FACTORY_COMMENT" "$TEMPLATE/$file" || fail "$file has no closing FACTORY_COMMENT line"
  if grep -qE "<<'?EOF|^EOF$" "$TEMPLATE/$file"; then
    fail "$file still uses the heredoc delimiter EOF"
  fi
done

# gh issue view rejects --comments together with --json.
case_count=$((case_count + 1))
for file in $(grep -rlF -- "--comments --json" "$TEMPLATE"); do
  fail "${file#"$TEMPLATE/"} uses gh issue view --comments --json, which gh rejects"
done

# The Guard fails open and only branch protection guards the remote main, so
# the README must not claim a pull request is the only way to reach main.
case_count=$((case_count + 1))
if grep -qF -- "only way work reaches" "$TEMPLATE/README.md"; then
  fail "README.md says the Guard makes a pull request the only way work reaches main"
fi

# The README names every flag of the install script and of serve.py, each at
# the start of a code span, so `git push --force` in the Guard section does
# not count as documenting --force.
case_count=$((case_count + 1))
for flag in --force --protect-main --no-protect-main --port --repo; do
  grep -qF -- "\`$flag" "$TEMPLATE/README.md" || fail "'$flag' is missing from README.md"
done

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
