#!/usr/bin/env bash
#
# Tests for src/software-factory-claude-code/factory/clean.sh, which removes
# the worktree and branch of every factory Job whose pull request was merged.
#
# Run: bash scripts/clean.test.sh
#
# Every case builds a real git repository with real worktrees under its
# .claude/worktrees/, and puts a fake gh on the PATH that answers canned
# issue and pull request JSON. The fake applies --jq with the system jq, as gh
# does with its built-in one, so no test reaches GitHub. Written for bash 3.2
# (the macOS default).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN="$SCRIPT_DIR/../src/software-factory-claude-code/factory/clean.sh"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# Keep the user's git config (signing, hooks, default branch) out of the
# fixtures.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

case_count=0
failure_count=0
case_name=""
case_dir=""
repo=""
call_log=""
output=""
status=0

# --- fixtures ---------------------------------------------------------------

# Starts a new case: a repository on main with one commit, no issues, and a
# fake gh.
begin_case() {
  case_count=$((case_count + 1))
  case_name="$1"
  case_dir="$WORK/case-$case_count"
  repo="$case_dir/repo"
  call_log="$case_dir/gh.log"
  mkdir -p "$case_dir/bin" "$case_dir/gh" "$case_dir/issues"
  : > "$call_log"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m "first"
  printf '0\n' > "$case_dir/gh/issue-list-exit"
  cat > "$case_dir/bin/gh" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$call_log"
filter=""
previous=""
for arg in "\$@"; do
  case "\$previous" in --jq | -q) filter="\$arg" ;; esac
  previous="\$arg"
done
case "\$1 \$2" in
  "issue list")
    exit_status="\$(cat "$case_dir/gh/issue-list-exit")"
    if [ "\$exit_status" -ne 0 ]; then printf 'HTTP 401: Bad credentials\n' >&2; exit "\$exit_status"; fi
    data="\$(/usr/bin/jq -s . "$case_dir"/issues/*.json 2> /dev/null || printf '[]')"
    ;;
  "pr view") data="\$(cat "$case_dir/gh/pr-\${3##*/}.json")" || exit 1 ;;
  "repo view") data='{"url":"https://github.com/octo/repo"}' ;;
  *) exit 1 ;;
esac
if [ -n "\$filter" ]; then printf '%s' "\$data" | /usr/bin/jq -r "\$filter"; else printf '%s\n' "\$data"; fi
FAKE
  chmod +x "$case_dir/bin/gh"
}

# Adds a closed factory issue. $1 is its number, $2 the PR URL in its `## pr`
# comment (empty: no such comment), $3 the worktree and $4 the branch in its
# latest `## state` comment. An older state comment names other paths, so the
# latest one must win.
add_issue() {
  /usr/bin/jq -n --argjson n "$1" --arg pr "$2" --arg wt "$3" --arg br "$4" '
    def state($wt; $br): "## state\n\n```json\n"
      + ({ id: "x", branch: $br, worktree: $wt, round: 1,
           reviews: { security: "PASS", ux: "PASS", ui: "PASS", code: "PASS" } } | tojson)
      + "\n```";
    { number: $n,
      comments: ([ { body: state("/old/worktree"; "factory/old") },
                   { body: "factory: claimed s1" },
                   { body: state($wt; $br) } ]
                 + (if $pr == "" then [] else [ { body: ("## pr\n" + $pr) } ] end)) }' \
    > "$case_dir/issues/$1.json"
}

# Makes the fake gh answer `gh pr view <url ending in $1>` with mergedAt $2
# (JSON: a quoted timestamp or null) and head branch $3.
pr_merged_at() {
  printf '{"mergedAt":%s,"headRefName":"%s"}\n' "$2" "$3" > "$case_dir/gh/pr-$1.json"
}

# Adds a worktree on branch $2 at $1, branched from main.
add_worktree() {
  git -C "$repo" worktree add -q -b "$2" "$1" main
}

# Runs clean.sh in the repository with the arguments given.
run_clean() {
  output="$(cd "$repo" && env PATH="$case_dir/bin:/usr/bin:/bin" bash "$CLEAN" "$@" 2>&1)"
  status=$?
}

# --- assertions -------------------------------------------------------------

fail() {
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n      %s\n' "$case_name" "$1"
}

assert_status() {
  [ "$status" -eq "$1" ] || fail "expected exit status $1, got $status. Output: $output"
}

assert_output_contains() {
  case "$output" in
    *"$1"*) ;;
    *) fail "expected output to contain '$1'. Output: $output" ;;
  esac
}

assert_output_lacks() {
  case "$output" in
    *"$1"*) fail "expected output not to contain '$1'. Output: $output" ;;
    *) ;;
  esac
}

assert_worktree_kept() {
  [ -d "$1" ] || fail "expected worktree $1 to exist"
  git -C "$repo" worktree list --porcelain | grep -qxF "worktree $1" \
    || fail "expected worktree $1 to stay registered"
}

assert_worktree_removed() {
  [ ! -e "$1" ] || fail "expected worktree $1 to be removed"
  if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $1"; then
    fail "expected worktree $1 to be unregistered"
  fi
}

assert_branch_kept() {
  git -C "$repo" show-ref --verify --quiet "refs/heads/$1" || fail "expected branch $1 to exist"
}

assert_branch_removed() {
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; then
    fail "expected branch $1 to be removed"
  fi
}

# --- cases ------------------------------------------------------------------

begin_case "merged job: worktree and branch removed"
worktree="$repo/.claude/worktrees/factory-1-a"
add_worktree "$worktree" factory/1-a
add_issue 1 "https://github.com/octo/repo/pull/7" "$worktree" factory/1-a
pr_merged_at 7 '"2026-10-10T12:00:00Z"' factory/1-a
run_clean
assert_status 0
assert_output_contains "removed #1: worktree $worktree, branch factory/1-a"
assert_worktree_removed "$worktree"
assert_branch_removed factory/1-a
grep -q "^issue list --label factory --state closed -L 500 --json number,comments" "$call_log" \
  || fail "expected the closed factory issues to be listed. gh calls: $(cat "$call_log")"
grep -q "^pr view https://github.com/octo/repo/pull/7 --json mergedAt,headRefName" "$call_log" \
  || fail "expected the PR to be read. gh calls: $(cat "$call_log")"

begin_case "unmerged PR: skipped, nothing removed"
worktree="$repo/.claude/worktrees/factory-2-b"
add_worktree "$worktree" factory/2-b
add_issue 2 "https://github.com/octo/repo/pull/8" "$worktree" factory/2-b
pr_merged_at 8 null factory/2-b
run_clean
assert_status 0
assert_output_contains "skip #2: pull request not merged"
assert_worktree_kept "$worktree"
assert_branch_kept factory/2-b

begin_case "dirty worktree: skipped and reported, worktree and branch kept"
worktree="$repo/.claude/worktrees/factory-3-c"
add_worktree "$worktree" factory/3-c
printf 'unsaved\n' > "$worktree/notes.txt"
add_issue 3 "https://github.com/octo/repo/pull/9" "$worktree" factory/3-c
pr_merged_at 9 '"2026-10-10T12:00:00Z"' factory/3-c
run_clean
assert_status 0
assert_output_contains "skip #3: git worktree remove refused:"
assert_output_contains "untracked"
assert_output_lacks "removed #3"
assert_worktree_kept "$worktree"
assert_branch_kept factory/3-c
[ -f "$worktree/notes.txt" ] || fail "expected the uncommitted file to survive"

begin_case "--dry-run removes nothing and prints would remove"
worktree="$repo/.claude/worktrees/factory-4-d"
add_worktree "$worktree" factory/4-d
add_issue 4 "https://github.com/octo/repo/pull/10" "$worktree" factory/4-d
pr_merged_at 10 '"2026-10-10T12:00:00Z"' factory/4-d
run_clean --dry-run
assert_status 0
assert_output_contains "would remove #4: worktree $worktree, branch factory/4-d"
assert_output_lacks "removed #4"
assert_worktree_kept "$worktree"
assert_branch_kept factory/4-d

begin_case "worktree already gone, branch present: branch removed"
git -C "$repo" branch factory/5-e
add_issue 5 "https://github.com/octo/repo/pull/11" "$repo/.claude/worktrees/factory-5-e" factory/5-e
pr_merged_at 11 '"2026-10-10T12:00:00Z"' factory/5-e
run_clean
assert_status 0
assert_output_contains "removed #5: branch factory/5-e"
assert_output_lacks "worktree $repo/.claude/worktrees/factory-5-e"
assert_branch_removed factory/5-e

begin_case "worktree and branch both gone: already clean"
add_issue 6 "https://github.com/octo/repo/pull/12" "$repo/.claude/worktrees/factory-6-f" factory/6-f
pr_merged_at 12 '"2026-10-10T12:00:00Z"' factory/6-f
run_clean
assert_status 0
assert_output_contains "skip #6: already clean"

begin_case "worktree outside .claude/worktrees/: skipped"
worktree="$case_dir/elsewhere"
add_worktree "$worktree" factory/7-g
add_issue 7 "https://github.com/octo/repo/pull/13" "$worktree" factory/7-g
pr_merged_at 13 '"2026-10-10T12:00:00Z"' factory/7-g
run_clean
assert_status 0
assert_output_contains "skip #7: worktree $worktree is not under $repo/.claude/worktrees/"
assert_worktree_kept "$worktree"
assert_branch_kept factory/7-g

begin_case "worktree path that climbs out with ..: skipped"
worktree="$case_dir/elsewhere"
add_worktree "$worktree" factory/8-h
add_issue 8 "https://github.com/octo/repo/pull/14" "$repo/.claude/worktrees/../../elsewhere" factory/8-h
pr_merged_at 14 '"2026-10-10T12:00:00Z"' factory/8-h
run_clean
assert_status 0
assert_output_contains "skip #8: worktree"
assert_worktree_kept "$worktree"
assert_branch_kept factory/8-h

begin_case "branch outside factory/: skipped"
worktree="$repo/.claude/worktrees/feature-x"
add_worktree "$worktree" feature/x
add_issue 9 "https://github.com/octo/repo/pull/15" "$worktree" feature/x
pr_merged_at 15 '"2026-10-10T12:00:00Z"' feature/x
run_clean
assert_status 0
assert_output_contains "skip #9: branch feature/x is not a factory/ branch"
assert_worktree_kept "$worktree"
assert_branch_kept feature/x

begin_case "no ## pr comment: skipped"
worktree="$repo/.claude/worktrees/factory-10-i"
add_worktree "$worktree" factory/10-i
add_issue 10 "" "$worktree" factory/10-i
run_clean
assert_status 0
assert_output_contains "skip #10: no ## pr comment"
assert_worktree_kept "$worktree"
assert_branch_kept factory/10-i

begin_case "pull request in another repo: skipped"
worktree="$repo/.claude/worktrees/factory-13-l"
add_worktree "$worktree" factory/13-l
add_issue 13 "https://github.com/someone/else/pull/17" "$worktree" factory/13-l
pr_merged_at 17 '"2026-10-10T12:00:00Z"' factory/13-l
run_clean
assert_status 0
assert_output_contains "skip #13: pull request https://github.com/someone/else/pull/17 is not in https://github.com/octo/repo"
assert_worktree_kept "$worktree"
assert_branch_kept factory/13-l

begin_case "pull request whose head is another branch: skipped"
worktree="$repo/.claude/worktrees/factory-14-m"
add_worktree "$worktree" factory/14-m
add_issue 14 "https://github.com/octo/repo/pull/18" "$worktree" factory/14-m
pr_merged_at 18 '"2026-10-10T12:00:00Z"' factory/99-other
run_clean
assert_status 0
assert_output_contains "skip #14: pull request head factory/99-other is not branch factory/14-m"
assert_worktree_kept "$worktree"
assert_branch_kept factory/14-m

begin_case "worktree checked out on another branch: skipped"
worktree="$repo/.claude/worktrees/factory-16-o"
add_worktree "$worktree" factory/16-o
git -C "$repo" branch factory/15-n
add_issue 15 "https://github.com/octo/repo/pull/19" "$worktree" factory/15-n
pr_merged_at 19 '"2026-10-10T12:00:00Z"' factory/15-n
run_clean
assert_status 0
assert_output_contains "skip #15: worktree $worktree is not checked out on branch factory/15-n"
assert_output_lacks "removed #15"
assert_worktree_kept "$worktree"
assert_branch_kept factory/16-o
assert_branch_kept factory/15-n

begin_case "every issue gets one line"
worktree="$repo/.claude/worktrees/factory-11-j"
add_worktree "$worktree" factory/11-j
add_issue 11 "https://github.com/octo/repo/pull/16" "$worktree" factory/11-j
pr_merged_at 16 '"2026-10-10T12:00:00Z"' factory/11-j
add_issue 12 "" "$repo/.claude/worktrees/factory-12-k" factory/12-k
run_clean
assert_status 0
[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ] || fail "expected two lines. Output: $output"
assert_output_contains "removed #11:"
assert_output_contains "skip #12:"

begin_case "failing gh issue list exits non-zero"
printf '1\n' > "$case_dir/gh/issue-list-exit"
run_clean
[ "$status" -ne 0 ] || fail "expected a non-zero exit status. Output: $output"
assert_output_contains "HTTP 401"

begin_case "unknown argument prints usage and exits 1"
run_clean --force
assert_status 1
assert_output_contains "Usage:"
[ ! -s "$call_log" ] || fail "expected no gh calls. gh calls: $(cat "$call_log")"

# --- summary ----------------------------------------------------------------

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
