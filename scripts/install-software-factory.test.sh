#!/usr/bin/env bash
#
# Tests for install-software-factory.sh.
#
# Run: bash scripts/install-software-factory.test.sh
#
# Every case builds its own fixture Template and Target under a temporary
# directory, pipes the Target path into the script, and asserts on the
# resulting file tree and output. Written for bash 3.2 (the macOS default).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-software-factory.sh"
REAL_TEMPLATE="$SCRIPT_DIR/../src/software-factory-claude-code"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

case_count=0
failure_count=0
case_name=""
case_dir=""
template=""
target=""
output=""
status=0

# --- fixtures ---------------------------------------------------------------

write_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

GITIGNORE_COMMENT="# Software factory job folders are runtime state"

EXPECTED_BACKLOG="# Backlog

- [ ] Open item"

# Starts a new case: an empty Target and a fixture Template with five files to
# install plus one Example job and one checked backlog item that must stay out.
begin_case() {
  case_count=$((case_count + 1))
  case_name="$1"
  case_dir="$WORK/case-$case_count"
  template="$case_dir/template"
  target="$case_dir/target"
  mkdir -p "$target"
  write_file "$template/.claude/agents/builder.md" "template builder"
  write_file "$template/.claude/skills/factory/SKILL.md" "template skill"
  write_file "$template/factory/backlog.md" "# Backlog

- [x] Done item → 001-example
- [ ] Open item"
  write_file "$template/factory/dashboard.html" "template dashboard"
  write_file "$template/factory/jobs/001-example/job.json" "example job"
  write_file "$template/README.md" "template readme"
}

# Runs the script against the fixture Template with $1 typed at the prompt.
run_install() {
  output="$(printf '%s\n' "$1" | SOFTWARE_FACTORY_TEMPLATE_DIR="$template" bash "$SCRIPT" 2>&1)"
  status=$?
}

# Prints every entry under $1 with its type and content checksum, so two
# snapshots are equal only when nothing was added, removed or changed.
snapshot() {
  (
    cd "$1" || exit 1
    find . -mindepth 1 | sort | while IFS= read -r entry; do
      if [ -L "$entry" ]; then
        printf 'link %s -> %s\n' "$entry" "$(readlink "$entry")"
      elif [ -d "$entry" ]; then
        printf 'dir  %s\n' "$entry"
      else
        printf 'file %s %s\n' "$entry" "$(cksum < "$entry")"
      fi
    done
  )
}

# --- assertions -------------------------------------------------------------

fail() {
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n      %s\n' "$case_name" "$1"
}

assert_status() {
  [ "$status" -eq "$1" ] || fail "expected exit status $1, got $status. Output: $output"
}

assert_failed() {
  [ "$status" -ne 0 ] || fail "expected a non-zero exit status. Output: $output"
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

assert_content() {
  if [ ! -f "$1" ]; then
    fail "expected file $1 to exist"
  elif [ "$(cat "$1")" != "$2" ]; then
    fail "expected $1 to contain '$2', got '$(cat "$1")'"
  fi
}

assert_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "expected $1 not to exist"
  fi
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3"
}

# --- cases ------------------------------------------------------------------

begin_case "empty Target receives every Template file"
run_install "$target"
assert_status 0
assert_content "$target/.claude/agents/builder.md" "template builder"
assert_content "$target/.claude/skills/factory/SKILL.md" "template skill"
assert_content "$target/factory/dashboard.html" "template dashboard"
assert_content "$target/README.md" "template readme"
assert_output_contains "5 added, 0 identical, 0 different"

begin_case "Example jobs are never copied and factory/jobs is left empty"
run_install "$target"
assert_status 0
assert_equal "" "$(ls -A "$target/factory/jobs" 2>&1)" "expected an empty factory/jobs directory"
assert_output_lacks "001-example"

begin_case "backlog.md is written without checked items"
run_install "$target"
assert_status 0
assert_content "$target/factory/backlog.md" "$EXPECTED_BACKLOG"
assert_output_contains "  factory/backlog.md"

begin_case "existing backlog.md keeps its checked items and is a different Skip"
write_file "$target/factory/backlog.md" "- [x] My item → 001-mine"
run_install "$target"
assert_status 0
assert_content "$target/factory/backlog.md" "- [x] My item → 001-mine"
assert_output_contains "4 added, 0 identical, 1 different"
assert_output_contains "  factory/backlog.md"

begin_case "existing jobs in the Target are left alone"
write_file "$target/factory/jobs/001-mine/job.json" "my job"
before="$(snapshot "$target/factory/jobs")"
run_install "$target"
assert_status 0
assert_equal "$before" "$(snapshot "$target/factory/jobs")" "expected factory/jobs to be unchanged"

begin_case "existing file with different content is a different Skip"
write_file "$target/README.md" "my readme"
run_install "$target"
assert_status 0
assert_content "$target/README.md" "my readme"
assert_output_contains "4 added, 0 identical, 1 different"
assert_output_contains "  README.md"

begin_case "existing file with identical content is an identical Skip"
write_file "$target/README.md" "template readme"
run_install "$target"
assert_status 0
assert_content "$target/README.md" "template readme"
assert_output_contains "4 added, 1 identical, 0 different"
assert_output_lacks "  README.md"

begin_case "Target .claude keeps every file unchanged and gains new ones"
write_file "$target/.claude/settings.json" "my settings"
write_file "$target/.claude/agents/builder.md" "my builder"
write_file "$target/.claude/agents/mine.md" "my agent"
write_file "$target/.claude/commands/deploy.md" "my command"
before="$(snapshot "$target/.claude")"
run_install "$target"
assert_status 0
assert_content "$target/.claude/settings.json" "my settings"
assert_content "$target/.claude/agents/builder.md" "my builder"
assert_content "$target/.claude/agents/mine.md" "my agent"
assert_content "$target/.claude/commands/deploy.md" "my command"
assert_content "$target/.claude/skills/factory/SKILL.md" "template skill"
rm -rf "$target/.claude/skills"
assert_equal "$before" "$(snapshot "$target/.claude")" \
  "expected .claude to differ from before only by the added skills directory"
assert_output_contains "4 added, 0 identical, 1 different"
assert_output_contains "  .claude/agents/builder.md"

begin_case "symlinked .claude in Target is a Conflict and nothing is copied"
write_file "$case_dir/shared/agents/mine.md" "shared agent"
ln -s ../shared "$target/.claude"
before="$(snapshot "$case_dir")"
run_install "$target"
assert_failed
assert_output_contains "Conflict"
assert_output_contains "  .claude"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "file where the Template has a directory is a Conflict"
write_file "$target/factory" "i am a file"
before="$(snapshot "$case_dir")"
run_install "$target"
assert_failed
assert_output_contains "Conflict"
assert_output_contains "  factory"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "nested file where the Template has a directory is a Conflict"
write_file "$target/.claude/agents" "i am a file"
before="$(snapshot "$case_dir")"
run_install "$target"
assert_failed
assert_output_contains "  .claude/agents"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "directory where the Template has a file is a different Skip"
write_file "$target/README.md/keep.txt" "keep me"
run_install "$target"
assert_status 0
assert_content "$target/README.md/keep.txt" "keep me"
assert_content "$target/factory/dashboard.html" "template dashboard"
assert_output_contains "4 added, 0 identical, 1 different"

begin_case "symlink where the Template has a file is a Skip and stays a symlink"
write_file "$target/NOTES.md" "my notes"
ln -s NOTES.md "$target/README.md"
run_install "$target"
assert_status 0
assert_equal "NOTES.md" "$(readlink "$target/README.md")" "expected README.md to stay a symlink"
assert_content "$target/NOTES.md" "my notes"
assert_output_contains "4 added, 0 identical, 1 different"

begin_case "missing .gitignore is created with the jobs rule"
run_install "$target"
assert_status 0
assert_content "$target/.gitignore" "$GITIGNORE_COMMENT
/factory/jobs/"
assert_output_contains ".gitignore: created"

begin_case "existing .gitignore gains the jobs rule and keeps its lines"
write_file "$target/.gitignore" "node_modules/
dist"
run_install "$target"
assert_status 0
assert_content "$target/.gitignore" "node_modules/
dist

$GITIGNORE_COMMENT
/factory/jobs/"
assert_output_contains ".gitignore: updated"

begin_case ".gitignore without a final newline keeps its last rule intact"
printf 'node_modules/\ndist' > "$target/.gitignore"
run_install "$target"
assert_status 0
assert_content "$target/.gitignore" "node_modules/
dist

$GITIGNORE_COMMENT
/factory/jobs/"

begin_case "empty .gitignore gains only the jobs rule"
: > "$target/.gitignore"
run_install "$target"
assert_status 0
assert_content "$target/.gitignore" "$GITIGNORE_COMMENT
/factory/jobs/"

for existing_rule in "/factory/jobs/" "/factory/jobs" "factory/jobs/" "factory/jobs"; do
  begin_case ".gitignore that already has '$existing_rule' is left alone"
  write_file "$target/.gitignore" "node_modules/
$existing_rule
dist"
  before="$(cksum < "$target/.gitignore")"
  run_install "$target"
  assert_status 0
  assert_equal "$before" "$(cksum < "$target/.gitignore")" "expected .gitignore to be unchanged"
  assert_output_contains ".gitignore: already ignores"
done

begin_case "symlinked .gitignore is not written through"
write_file "$case_dir/shared-gitignore" "node_modules/"
ln -s ../shared-gitignore "$target/.gitignore"
run_install "$target"
assert_status 0
assert_content "$case_dir/shared-gitignore" "node_modules/"
assert_equal "../shared-gitignore" "$(readlink "$target/.gitignore")" "expected .gitignore to stay a symlink"
assert_output_contains ".gitignore: skipped"
assert_output_contains "/factory/jobs/"

begin_case "second run does not repeat the jobs rule"
run_install "$target"
run_install "$target"
assert_status 0
assert_equal "1" "$(grep -c -x '/factory/jobs/' "$target/.gitignore")" "expected the jobs rule exactly once"

begin_case "missing Target aborts and is not created"
run_install "$case_dir/does-not-exist"
assert_failed
assert_output_contains "does not exist"
assert_missing "$case_dir/does-not-exist"

begin_case "Target that is a file aborts"
write_file "$case_dir/a-file" "i am a file"
run_install "$case_dir/a-file"
assert_failed
assert_content "$case_dir/a-file" "i am a file"

begin_case "empty input aborts"
before="$(snapshot "$case_dir")"
run_install ""
assert_failed
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "Target equal to the Template aborts"
before="$(snapshot "$case_dir")"
run_install "$template"
assert_failed
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "Target inside the Template aborts"
before="$(snapshot "$case_dir")"
run_install "$template/factory"
assert_failed
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "leading tilde expands to the home directory"
output="$(printf '%s\n' "~/target" | HOME="$case_dir" SOFTWARE_FACTORY_TEMPLATE_DIR="$template" bash "$SCRIPT" 2>&1)"
status=$?
assert_status 0
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "relative path resolves against the current directory"
output="$(cd "$case_dir" && printf '%s\n' "target" | SOFTWARE_FACTORY_TEMPLATE_DIR="$template" bash "$SCRIPT" 2>&1)"
status=$?
assert_status 0
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "Target path with spaces works"
target="$case_dir/my target"
mkdir -p "$target"
run_install "$target"
assert_status 0
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "second run on the same Target adds nothing"
run_install "$target"
before="$(snapshot "$target")"
run_install "$target"
assert_status 0
assert_output_contains "0 added, 5 identical, 0 different"
assert_equal "$before" "$(snapshot "$target")" "expected the second run to change nothing"

begin_case "Target outside a git repository gets a warning but is copied"
run_install "$target"
assert_status 0
assert_output_contains "not a git repository"

begin_case "Target inside a git repository gets no warning"
git init -q "$target"
run_install "$target"
assert_status 0
assert_output_lacks "not a git repository"

begin_case "the real Template is used when no override is set"
output="$(printf '%s\n' "$target" | bash "$SCRIPT" 2>&1)"
status=$?
assert_status 0
assert_equal "" "$(diff -r -x .DS_Store -x .gitignore -x jobs -x backlog.md "$REAL_TEMPLATE" "$target" 2>&1)" \
  "expected the Target to match the real Template apart from jobs and backlog.md"
assert_equal "" "$(ls -A "$target/factory/jobs" 2>&1)" "expected an empty factory/jobs directory"
assert_equal "0" "$(grep -c -E '^- \[[xX]\]' "$target/factory/backlog.md")" \
  "expected no checked items in backlog.md"
assert_equal "$(grep -c '' "$REAL_TEMPLATE/factory/backlog.md")" \
  "$(($(grep -c '' "$target/factory/backlog.md") + $(grep -c -E '^- \[[xX]\]' "$REAL_TEMPLATE/factory/backlog.md")))" \
  "expected backlog.md to lose only its checked items"

# --- summary ----------------------------------------------------------------

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
