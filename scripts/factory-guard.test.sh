#!/usr/bin/env bash
#
# Tests for the factory Guard, the PreToolUse hook in
# src/software-factory-claude-code/.claude/hooks/factory-guard.sh.
#
# Run: bash scripts/factory-guard.test.sh
#
# Every case pipes hook JSON into the Guard, the way the harness does before a
# Bash call, and asserts on its exit status and stderr. The commit cases use
# real temporary git repositories, so the Guard reads a real current branch.
# Written for bash 3.2 (the macOS default).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../src/software-factory-claude-code/.claude/hooks/factory-guard.sh"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

case_count=0
failure_count=0
case_name=""
status=0
stderr=""
stdout=""

# --- fixtures ---------------------------------------------------------------

# Two repositories with no commits: one on main, one on a job branch. The
# Guard only reads the current branch, so neither needs a commit.
ON_MAIN="$WORK/on-main"
ON_JOB="$WORK/on-job"
NOT_A_REPO="$WORK/not-a-repo"
git init -q "$ON_MAIN" && git -C "$ON_MAIN" symbolic-ref HEAD refs/heads/main
git init -q "$ON_JOB" && git -C "$ON_JOB" symbolic-ref HEAD refs/heads/factory/1-a
mkdir -p "$NOT_A_REPO"

begin_case() {
  case_count=$((case_count + 1))
  case_name="$1"
}

# Prints $1 as a JSON string literal, escaping backslashes, quotes, tabs and
# newlines the way the harness does.
json_string() {
  local s="$1" bs='\'
  s="${s//"$bs"/$bs$bs}"
  s="${s//\"/$bs\"}"
  s="${s//$'\t'/${bs}t}"
  s="${s//$'\n'/${bs}n}"
  printf '"%s"' "$s"
}

# Pipes raw hook JSON ($1) into the Guard. Sets $status, $stdout and $stderr.
run_raw() {
  stdout="$(printf '%s' "$1" | bash "$GUARD" 2> "$WORK/stderr")"
  status=$?
  stderr="$(cat "$WORK/stderr")"
}

# Runs the Guard on Bash command $1, with the session's cwd $2 (default: the
# repository on a job branch).
run_guard() {
  run_raw "{\"session_id\":\"s1\",\"cwd\":$(json_string "${2:-$ON_JOB}"),\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_string "$1"),\"description\":\"test\"}}"
}

# --- assertions -------------------------------------------------------------

fail() {
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n      %s\n' "$case_name" "$1"
}

# Exit 2, nothing on stdout, and exactly one stderr line naming the Guard.
assert_blocked() {
  [ "$status" -eq 2 ] || fail "expected exit status 2, got $status. Stderr: $stderr"
  case "$stderr" in
    "factory-guard: "*) ;;
    *) fail "expected stderr to start with 'factory-guard: ', got '$stderr'" ;;
  esac
  case "$stderr" in
    *$'\n'*) fail "expected one stderr line, got '$stderr'" ;;
  esac
  case "$stderr" in
    *"pull request"*) ;;
    *) fail "expected stderr to mention a pull request, got '$stderr'" ;;
  esac
  [ -z "$stdout" ] || fail "expected no stdout, got '$stdout'"
}

# Exit 0 and no output at all.
assert_allowed() {
  [ "$status" -eq 0 ] || fail "expected exit status 0, got $status. Stderr: $stderr"
  [ -z "$stderr" ] || fail "expected no stderr, got '$stderr'"
  [ -z "$stdout" ] || fail "expected no stdout, got '$stdout'"
}

assert_stderr_contains() {
  case "$stderr" in
    *"$1"*) ;;
    *) fail "expected stderr to contain '$1', got '$stderr'" ;;
  esac
}

# --- blocked ----------------------------------------------------------------

begin_case "git merge is blocked"
run_guard "git merge --no-ff main"
assert_blocked
assert_stderr_contains "git merge"

begin_case "git merge after cd is blocked"
run_guard "cd /x && git merge factory/1-a"
assert_blocked

begin_case "gh pr merge is blocked"
run_guard "gh pr merge 6 --squash"
assert_blocked
assert_stderr_contains "gh pr merge"

begin_case "git push to main is blocked"
run_guard "git push origin main"
assert_blocked
assert_stderr_contains "main"

begin_case "git push HEAD:main is blocked"
run_guard "git push origin HEAD:main"
assert_blocked

begin_case "git push refs/heads/main is blocked"
run_guard "git push origin refs/heads/main"
assert_blocked

begin_case "git push +main is blocked"
run_guard "git push origin +main"
assert_blocked

begin_case "git push :main is blocked"
run_guard "git push origin :main"
assert_blocked

begin_case "git push <x>:refs/heads/main is blocked"
run_guard "git push origin factory/1-a:refs/heads/main"
assert_blocked

begin_case "git push --force is blocked"
run_guard "git push --force origin factory/1-a"
assert_blocked
assert_stderr_contains "--force"

begin_case "git push -f is blocked"
run_guard "git push -f"
assert_blocked

begin_case "git push --force-with-lease is blocked"
run_guard "git push --force-with-lease"
assert_blocked

begin_case "git push --force-with-lease=<ref> is blocked"
run_guard "git push --force-with-lease=factory/1-a origin factory/1-a"
assert_blocked

begin_case "git branch -D is blocked"
run_guard "git branch -D factory/1-a"
assert_blocked
assert_stderr_contains "git branch -D"

begin_case "git branch --delete --force is blocked"
run_guard "git branch --delete --force factory/1-a"
assert_blocked

begin_case "git commit with the session cwd on main is blocked"
run_guard "git commit -m x" "$ON_MAIN"
assert_blocked
assert_stderr_contains "git commit on main"

begin_case "git commit after cd into a repo on main is blocked"
run_guard "cd $ON_MAIN && git commit -m x" "$ON_JOB"
assert_blocked

begin_case "git commit after cd into a quoted path on main is blocked"
run_guard "cd \"$ON_MAIN\" && git add a.txt && git commit -m x" "$ON_JOB"
assert_blocked

begin_case "a blocked command on a later line is blocked"
run_guard "git status
git merge factory/1-a"
assert_blocked

begin_case "a blocked command after a semicolon, pipe or paren is blocked"
for command in "ls; git merge x" "ls || git merge x" "ls | git merge x" "(git merge x)" "echo \$(git merge x)"; do
  run_guard "$command"
  assert_blocked
done

begin_case "a blocked command after a heredoc ends is blocked"
run_guard "cat > notes.md <<'EOF'
notes
EOF
git merge factory/1-a"
assert_blocked

begin_case "hand-written JSON with escaped quotes is parsed"
run_raw '{"cwd":"/tmp","tool_input":{"command":"git commit -m \"x\" && git push origin main"}}'
assert_blocked

# --- allowed ----------------------------------------------------------------

begin_case "git merge-tree is allowed"
run_guard "git merge-tree --write-tree origin/main factory/1-a"
assert_allowed

begin_case "git merge-base is allowed"
run_guard "git merge-base main HEAD"
assert_allowed

begin_case "git mergetool is allowed"
run_guard "git mergetool"
assert_allowed

begin_case "gh pr view is allowed"
run_guard "gh pr view 6"
assert_allowed

begin_case "gh pr create to main is allowed"
run_guard "gh pr create --base main --head factory/1-a"
assert_allowed

begin_case "git push of a job branch whose name contains main is allowed"
run_guard "git push -u origin factory/12-fix-main-menu"
assert_allowed

begin_case "git fetch of main is allowed"
run_guard "git fetch origin main"
assert_allowed

begin_case "git branch -d is allowed"
run_guard "git branch -d factory/1-a"
assert_allowed

begin_case "git commit on a job branch is allowed"
run_guard "git commit -m x" "$ON_JOB"
assert_allowed

begin_case "git commit after cd into a repo on a job branch is allowed"
run_guard "cd $ON_JOB && git commit -m x" "$ON_MAIN"
assert_allowed

begin_case "git commit-tree on main is allowed"
run_guard "git commit-tree HEAD^{tree} -m x" "$ON_MAIN"
assert_allowed

begin_case "git commit outside a git repository is allowed"
run_guard "git commit -m x" "$NOT_A_REPO"
assert_allowed

begin_case "a blocked command inside a quoted argument is allowed"
run_guard 'git commit -m "explain git merge"'
assert_allowed

begin_case "a blocked command after a separator inside quotes is allowed"
run_guard 'git commit -m "first; git merge x
git push --force origin main"'
assert_allowed

begin_case "a heredoc body that quotes blocked commands is allowed"
run_guard "gh issue comment 7 --body-file - <<'EOF'
## round-1 review-code
VERDICT: PASS

git push --force origin main
git merge factory/1-a
EOF"
assert_allowed

begin_case "a heredoc inside a command substitution is allowed"
run_guard "git commit -m \"\$(cat <<'EOF'
fix: say \"why\"
git merge is blocked now
EOF
)\" && git log --oneline -1"
assert_allowed

begin_case "an ordinary command is allowed"
run_guard "ls"
assert_allowed

# --- malformed input ----------------------------------------------------------

begin_case "stdin that is not JSON is allowed"
run_raw "not json"
assert_allowed

begin_case "JSON without a command is allowed"
run_raw '{"cwd":"/tmp","tool_input":{}}'
assert_allowed

begin_case "empty stdin is allowed"
run_raw ""
assert_allowed

# --- summary ----------------------------------------------------------------

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
