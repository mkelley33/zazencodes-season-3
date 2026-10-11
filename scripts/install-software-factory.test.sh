#!/usr/bin/env bash
#
# Tests for install-software-factory.sh.
#
# Run: bash scripts/install-software-factory.test.sh
#
# Every case builds its own fixture Template and Target under a temporary
# directory, pipes the Target path into the script, and asserts on the
# resulting file tree and output. Written for bash 3.2 (the macOS default).
#
# The script never sees the real PATH: it gets the case's own bin directory
# plus the system directories, so no test can reach Homebrew or the network.

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
call_log=""
gh_log=""
run_path=""
run_home=""
run_cwd=""
output=""
status=0

# --- fixtures ---------------------------------------------------------------

write_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

# Starts a new case: an empty Target and a fixture Template with four files to
# install. agent-browser and gh are on the PATH unless a case removes them.
# main has no protection yet and setting it succeeds.
begin_case() {
  case_count=$((case_count + 1))
  case_name="$1"
  case_dir="$WORK/case-$case_count"
  template="$case_dir/template"
  target="$case_dir/target"
  call_log="$case_dir/calls.log"
  gh_log="$case_dir/gh.log"
  run_path="$case_dir/bin:/usr/bin:/bin"
  run_home="$HOME"
  run_cwd="$WORK"
  mkdir -p "$target" "$case_dir/bin"
  : > "$call_log"
  : > "$gh_log"
  fake_command agent-browser 0
  fake_gh 1 0
  write_file "$template/.claude/agents/builder.md" "template builder"
  write_file "$template/.claude/skills/factory/SKILL.md" "template skill"
  write_file "$template/factory/dashboard.html" "template dashboard"
  write_file "$template/README.md" "template readme"
}

# Puts a fake command named $1 on the case's PATH. It records its arguments in
# the call log, runs the optional shell code in $3, and exits with status $2.
fake_command() {
  cat > "$case_dir/bin/$1" <<FAKE
#!/bin/bash
printf '%s %s\n' "$1" "\$*" >> "$call_log"
${3:-}
exit $2
FAKE
  chmod +x "$case_dir/bin/$1"
}

# Puts a fake gh on the case's PATH that records its arguments in its own log,
# so the brew and agent-browser call log stays as it was. `gh repo view`
# answers octo/repo and saves the directory it ran in. Reading main's
# protection exits with status $1 and setting it exits with status $2, saving
# the JSON it was given. A failing call prints gh's error line on stderr.
fake_gh() {
  cat > "$case_dir/bin/gh" <<FAKE
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$gh_log"
case "\$*" in
  "repo view"*) pwd -P > "$case_dir/gh-repo-view.cwd"; printf 'octo/repo\n' ;;
  "api -X PUT "*)
    cat > "$case_dir/gh-put.json"
    [ $2 -eq 0 ] || { printf 'HTTP 403: Resource not accessible by integration\n' >&2; exit $2; } ;;
  "api "*) [ $1 -eq 0 ] || { printf 'gh: Branch not protected (HTTP 404)\n' >&2; exit $1; } ;;
esac
exit 0
FAKE
  chmod +x "$case_dir/bin/gh"
}

# Copies the real Template's settings.json, which holds the Guard, into the
# fixture Template. The other cases keep their four-file fixture.
add_template_settings() {
  cp "$REAL_TEMPLATE/.claude/settings.json" "$template/.claude/settings.json"
}

# Runs the script with only the case's bin directory on the PATH, holding
# links to every tool the script uses except jq.
hide_jq() {
  for tool in bash cat cmp cp dirname find git mktemp rm rsync sed sort tail; do
    ln -s "$(command -v "$tool")" "$case_dir/bin/$tool"
  done
  run_path="$case_dir/bin"
}

# Makes agent-browser missing, with a fake Homebrew that installs a fake
# agent-browser whose own commands exit with status $1.
agent_browser_missing_with_brew() {
  fake_command agent-browser "$1"
  mv "$case_dir/bin/agent-browser" "$case_dir/agent-browser.fake"
  fake_command brew 0 "cp '$case_dir/agent-browser.fake' '$case_dir/bin/agent-browser'"
}

# Runs the script with $1 typed at the prompt and the remaining arguments
# passed to it. Uses the fixture Template, or the real one when $template is
# empty.
run_install() {
  typed="$1"
  shift
  output="$(cd "$run_cwd" && printf '%s\n' "$typed" | env PATH="$run_path" \
    HOME="$run_home" SOFTWARE_FACTORY_TEMPLATE_DIR="$template" bash "$SCRIPT" "$@" 2>&1)"
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
assert_output_contains "4 added, 0 identical, 0 different"

begin_case "install writes no job folders, backlog or .gitignore"
run_install "$target"
assert_status 0
assert_missing "$target/factory/jobs"
assert_missing "$target/factory/backlog.md"
assert_missing "$target/.gitignore"
assert_output_lacks ".gitignore"

begin_case "existing .gitignore is left alone"
write_file "$target/.gitignore" "node_modules/"
run_install "$target"
assert_status 0
assert_content "$target/.gitignore" "node_modules/"

begin_case "existing file with different content is a different Skip"
write_file "$target/README.md" "my readme"
run_install "$target"
assert_status 0
assert_content "$target/README.md" "my readme"
assert_output_contains "3 added, 0 identical, 1 different"
assert_output_contains "  README.md"

begin_case "existing file with identical content is an identical Skip"
write_file "$target/README.md" "template readme"
run_install "$target"
assert_status 0
assert_content "$target/README.md" "template readme"
assert_output_contains "3 added, 1 identical, 0 different"
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
assert_output_contains "3 added, 0 identical, 1 different"
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
assert_output_contains "3 added, 0 identical, 1 different"

begin_case "symlink where the Template has a file is a Skip and stays a symlink"
write_file "$target/NOTES.md" "my notes"
ln -s NOTES.md "$target/README.md"
run_install "$target"
assert_status 0
assert_equal "NOTES.md" "$(readlink "$target/README.md")" "expected README.md to stay a symlink"
assert_content "$target/NOTES.md" "my notes"
assert_output_contains "3 added, 0 identical, 1 different"

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
run_home="$case_dir"
run_install "~/target"
assert_status 0
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "relative path resolves against the current directory"
run_cwd="$case_dir"
run_install "target"
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
assert_output_contains "0 added, 4 identical, 0 different"
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

begin_case "gh on the PATH gets no warning"
run_install "$target"
assert_status 0
assert_output_contains "gh: found"
assert_output_lacks "https://cli.github.com"

begin_case "missing gh prints a warning after the report and continues"
rm "$case_dir/bin/gh"
run_install "$target"
assert_status 0
assert_output_contains "gh: not installed"
assert_output_contains "https://cli.github.com"
assert_content "$target/factory/dashboard.html" "template dashboard"
case "$output" in
  *"Done: 4 added"*"gh: not installed"*) ;;
  *) fail "expected the copy report before the gh check. Output: $output" ;;
esac

begin_case "agent-browser already on the PATH is not installed again"
fake_command brew 0
run_install "$target"
assert_status 0
assert_output_contains "agent-browser: already installed"
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"

begin_case "--install-agent-browser with agent-browser on the PATH installs nothing"
fake_command brew 0
run_install "$target" --install-agent-browser
assert_status 0
assert_output_contains "agent-browser: already installed"
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"

begin_case "missing agent-browser is not installed without --install-agent-browser"
agent_browser_missing_with_brew 0
run_install "$target"
assert_status 0
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"
assert_output_contains "agent-browser: not installed"
assert_output_contains "--install-agent-browser"
assert_output_contains "brew install agent-browser && agent-browser install"
assert_content "$target/factory/dashboard.html" "template dashboard"
case "$output" in
  *"Done: 4 added"*"agent-browser: not installed"*) ;;
  *) fail "expected the copy report before the agent-browser step. Output: $output" ;;
esac

begin_case "missing agent-browser without Homebrew prints the manual steps without the flag"
rm "$case_dir/bin/agent-browser"
run_install "$target"
assert_status 0
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"
assert_output_contains "brew install agent-browser && agent-browser install"
assert_output_contains "https://github.com/vercel-labs/agent-browser"

begin_case "--install-agent-browser installs a missing agent-browser with Homebrew after the report"
agent_browser_missing_with_brew 0
run_install "$target" --install-agent-browser
assert_status 0
assert_equal "brew install agent-browser
agent-browser install" "$(cat "$call_log")" "expected brew install, then agent-browser install"
assert_output_contains "agent-browser: installed"
case "$output" in
  *"Done: 4 added"*"agent-browser: installing"*) ;;
  *) fail "expected the copy report before the agent-browser step. Output: $output" ;;
esac

begin_case "--install-agent-browser without Homebrew prints manual steps and continues"
rm "$case_dir/bin/agent-browser"
run_install "$target" --install-agent-browser
assert_status 0
assert_output_contains "Homebrew was not found"
assert_output_contains "https://github.com/vercel-labs/agent-browser"
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"

begin_case "failed brew install exits non-zero but keeps the copy"
rm "$case_dir/bin/agent-browser"
fake_command brew 1
run_install "$target" --install-agent-browser
assert_failed
assert_equal "brew install agent-browser" "$(cat "$call_log")" "expected only the brew install call"
assert_output_contains "https://github.com/vercel-labs/agent-browser"
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "failed agent-browser install exits non-zero but keeps the copy"
agent_browser_missing_with_brew 1
run_install "$target" --install-agent-browser
assert_failed
assert_output_contains "https://github.com/vercel-labs/agent-browser"
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "Conflict aborts before the agent-browser step"
agent_browser_missing_with_brew 0
write_file "$target/factory" "i am a file"
run_install "$target" --install-agent-browser
assert_failed
assert_equal "" "$(cat "$call_log")" "expected no brew or agent-browser calls"

begin_case "--install-agent-browser given twice is rejected before the prompt"
agent_browser_missing_with_brew 0
before="$(snapshot "$case_dir")"
run_install "$target" --install-agent-browser --install-agent-browser
assert_failed
assert_output_contains "--install-agent-browser"
assert_output_lacks "Target path:"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "--install-agent-browser combines with --force and --no-protect-main in any order"
agent_browser_missing_with_brew 0
write_file "$target/README.md" "my readme"
run_install "$target" --no-protect-main --install-agent-browser --force
assert_status 0
assert_content "$target/README.md" "template readme"
assert_output_contains "main protection: skipped (--no-protect-main)."
assert_output_contains "agent-browser: installed"

begin_case "the real Template is used when no override is set"
template=""
run_install "$target"
assert_status 0
assert_equal "" "$(diff -r -x .DS_Store "$REAL_TEMPLATE" "$target" 2>&1)" \
  "expected the Target to match the real Template"
assert_missing "$target/factory/jobs"
assert_missing "$target/factory/backlog.md"

begin_case "no-flag output has no Overwrite count"
write_file "$target/README.md" "my readme"
run_install "$target"
assert_status 0
assert_content "$target/README.md" "my readme"
assert_output_contains "Done: 3 added, 0 identical, 1 different."
assert_output_lacks "overwritten"
assert_output_lacks "Overwritten"

begin_case "--force overwrites a file with different content"
write_file "$target/README.md" "my readme"
run_install "$target" --force
assert_status 0
assert_content "$target/README.md" "template readme"
assert_output_contains "Overwritten (1):
  README.md"
assert_output_contains "Done: 3 added, 0 identical, 0 different, 1 overwritten."

begin_case "--force overwrites a nested different file and keeps the rest"
write_file "$target/.claude/settings.json" "my settings"
write_file "$target/.claude/agents/builder.md" "my builder"
write_file "$target/.claude/agents/mine.md" "my agent"
run_install "$target" --force
assert_status 0
assert_content "$target/.claude/agents/builder.md" "template builder"
assert_content "$target/.claude/settings.json" "my settings"
assert_content "$target/.claude/agents/mine.md" "my agent"
assert_output_contains "Overwritten (1):
  .claude/agents/builder.md"
assert_output_contains "Done: 3 added, 0 identical, 0 different, 1 overwritten."

begin_case "--force does not report an identical file as overwritten"
write_file "$target/README.md" "template readme"
run_install "$target" --force
assert_status 0
assert_content "$target/README.md" "template readme"
assert_output_contains "Done: 3 added, 1 identical, 0 different, 0 overwritten."
assert_output_lacks "Overwritten ("

begin_case "--force leaves a directory where the Template has a file"
write_file "$target/README.md/keep.txt" "keep me"
run_install "$target" --force
assert_status 0
assert_content "$target/README.md/keep.txt" "keep me"
assert_output_contains "Skipped, different content (1). Left unchanged, compare by hand:
  README.md"
assert_output_contains "1 different, 0 overwritten"

begin_case "--force leaves a symlink where the Template has a file"
write_file "$target/NOTES.md" "my notes"
ln -s NOTES.md "$target/README.md"
run_install "$target" --force
assert_status 0
assert_equal "NOTES.md" "$(readlink "$target/README.md")" "expected README.md to stay a symlink"
assert_content "$target/NOTES.md" "my notes"
assert_output_contains "1 different, 0 overwritten"

begin_case "--force still aborts on a Conflict and overwrites nothing"
write_file "$target/factory" "i am a file"
write_file "$target/README.md" "my readme"
before="$(snapshot "$case_dir")"
run_install "$target" --force
assert_failed
assert_output_contains "Conflict"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "unknown flag is rejected before the prompt"
before="$(snapshot "$case_dir")"
run_install "$target" --frce
assert_failed
assert_output_contains "--force"
assert_output_lacks "Target path:"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "positional argument is rejected before the prompt"
before="$(snapshot "$case_dir")"
run_install "$target" extra
assert_failed
assert_output_contains "--force"
assert_output_lacks "Target path:"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "--force given twice is rejected before the prompt"
write_file "$target/README.md" "my readme"
before="$(snapshot "$case_dir")"
run_install "$target" --force --force
assert_failed
assert_output_contains "--force"
assert_output_lacks "Target path:"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

# --- Hook merge ---------------------------------------------------------------

# shellcheck disable=SC2016 # the hook command is stored literally
GUARD_COMMAND='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/factory-guard.sh"'
MY_SETTINGS='{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"node mine.mjs"}]}]}}'
FACTORY_RULES='"Bash(gh issue comment *)","Bash(gh issue edit *)"'

# Prints how many PreToolUse hooks in $1 run the Guard.
guard_count() {
  jq --arg c "$GUARD_COMMAND" '[.hooks.PreToolUse[].hooks[] | select(.command == $c)] | length' "$1"
}

begin_case "Hook merge adds the Guard and the permission rules to an existing settings.json once"
add_template_settings
write_file "$target/.claude/settings.json" "$MY_SETTINGS"
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: added the Guard and the permission rules to .claude/settings.json."
assert_output_contains "Hook merge: these rules now run without a prompt: Bash(gh issue comment *), Bash(gh issue edit *)."
assert_output_contains "4 added, 0 identical, 1 different"
assert_output_contains "  .claude/settings.json (apart from the Hook merge above)"
assert_equal "1" "$(guard_count "$target/.claude/settings.json")" "expected the Guard exactly once"
assert_equal "[\"Bash(ls)\",$FACTORY_RULES]" "$(jq -c .permissions.allow "$target/.claude/settings.json")" \
  "expected the Target's own rule first, then each factory rule once"
assert_equal '{"matcher":"Write","hooks":[{"type":"command","command":"node mine.mjs"}]}' \
  "$(jq -c '.hooks.PreToolUse[0]' "$target/.claude/settings.json")" \
  "expected the Target's own PreToolUse hook to stay first and unchanged"
assert_equal "2" "$(jq '.hooks.PreToolUse | length' "$target/.claude/settings.json")" \
  "expected two PreToolUse entries"

begin_case "second Hook merge leaves settings.json byte-identical"
add_template_settings
write_file "$target/.claude/settings.json" "$MY_SETTINGS"
run_install "$target"
before="$(cksum < "$target/.claude/settings.json")"
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: .claude/settings.json already has the Guard and the permission rules."
assert_output_lacks "Hook merge: added"
assert_output_lacks "rules now run without a prompt"
assert_equal "$before" "$(cksum < "$target/.claude/settings.json")" "expected the second run to change nothing"

begin_case "Hook merge creates hooks and permissions when the Target settings have neither"
add_template_settings
write_file "$target/.claude/settings.json" '{"model":"opus"}'
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: added the Guard and the permission rules to .claude/settings.json."
assert_output_contains "Hook merge: these rules now run without a prompt: Bash(gh issue comment *), Bash(gh issue edit *)."
assert_equal "1" "$(guard_count "$target/.claude/settings.json")" "expected the Guard exactly once"
assert_equal "[$FACTORY_RULES]" "$(jq -c .permissions.allow "$target/.claude/settings.json")" \
  "expected both factory rules"
assert_equal '"opus"' "$(jq -c .model "$target/.claude/settings.json")" "expected model to stay"

begin_case "Hook merge adds only the permission rules when the Guard is already there"
add_template_settings
write_file "$target/.claude/settings.json" "$(jq -c 'del(.permissions)' "$template/.claude/settings.json")"
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: added the permission rules to .claude/settings.json."
assert_output_contains "Hook merge: these rules now run without a prompt: Bash(gh issue comment *), Bash(gh issue edit *)."
assert_equal "1" "$(guard_count "$target/.claude/settings.json")" "expected the Guard exactly once"
assert_equal "[$FACTORY_RULES]" "$(jq -c .permissions.allow "$target/.claude/settings.json")" \
  "expected both factory rules"

begin_case "Hook merge adds only the Guard when the permission rules are already there"
add_template_settings
write_file "$target/.claude/settings.json" "{\"permissions\":{\"allow\":[\"Bash(gh issue edit *)\",\"Bash(ls)\",\"Bash(gh issue comment *)\"]}}"
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: added the Guard to .claude/settings.json."
assert_output_lacks "rules now run without a prompt"
assert_equal "1" "$(guard_count "$target/.claude/settings.json")" "expected the Guard exactly once"
assert_equal '["Bash(gh issue edit *)","Bash(ls)","Bash(gh issue comment *)"]' \
  "$(jq -c .permissions.allow "$target/.claude/settings.json")" "expected the rules to stay as they were"

begin_case "Hook merge adds only the missing rule and keeps the other permission keys"
add_template_settings
write_file "$target/.claude/settings.json" '{"permissions":{"defaultMode":"acceptEdits","deny":["Bash(rm *)"],"allow":["Bash(gh issue comment *)"],"ask":["Bash(git push *)"]}}'
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: this rule now runs without a prompt: Bash(gh issue edit *)."
assert_equal '{"defaultMode":"acceptEdits","deny":["Bash(rm *)"],"allow":["Bash(gh issue comment *)","Bash(gh issue edit *)"],"ask":["Bash(git push *)"]}' \
  "$(jq -c .permissions "$target/.claude/settings.json")" \
  "expected only Bash(gh issue edit *) added and every other permission key kept"

begin_case "--force does not Overwrite a different settings.json but Hook merges it"
add_template_settings
write_file "$target/.claude/settings.json" "$MY_SETTINGS"
run_install "$target" --force
assert_status 0
assert_output_contains "Done: 4 added, 0 identical, 1 different, 0 overwritten."
assert_output_lacks "Overwritten ("
assert_output_contains "Hook merge: added the Guard and the permission rules"
assert_equal "[\"Bash(ls)\",$FACTORY_RULES]" "$(jq -c .permissions.allow "$target/.claude/settings.json")" \
  "expected the Target's own rule to survive --force"
assert_equal "1" "$(guard_count "$target/.claude/settings.json")" "expected the Guard exactly once"

begin_case "settings.json identical to the Template's is not touched"
add_template_settings
mkdir -p "$target/.claude"
cp "$template/.claude/settings.json" "$target/.claude/settings.json"
before="$(cksum < "$target/.claude/settings.json")"
run_install "$target"
assert_status 0
assert_output_contains "4 added, 1 identical, 0 different"
assert_output_lacks "Hook merge"
assert_equal "$before" "$(cksum < "$target/.claude/settings.json")" "expected settings.json unchanged"

begin_case "missing jq warns, prints the hooks and rules and leaves settings.json alone"
add_template_settings
write_file "$target/.claude/settings.json" "$MY_SETTINGS"
before="$(cksum < "$target/.claude/settings.json")"
hide_jq
run_install "$target" --no-protect-main
assert_status 0
assert_output_contains "Hook merge: jq was not found"
assert_output_contains "Add the hooks and permission rules below to it by hand:"
assert_output_contains '"PreToolUse"'
assert_output_contains "factory-guard.sh"
assert_output_contains '"Bash(gh issue edit *)"'
assert_output_lacks "Hook merge: added"
assert_equal "$before" "$(cksum < "$target/.claude/settings.json")" "expected settings.json unchanged"
assert_content "$target/factory/dashboard.html" "template dashboard"

begin_case "invalid settings.json warns and is left alone"
add_template_settings
write_file "$target/.claude/settings.json" '{"permissions": '
before="$(cksum < "$target/.claude/settings.json")"
run_install "$target"
assert_status 0
assert_output_contains "Hook merge: could not merge"
assert_output_contains "Add the hooks and permission rules below to it by hand:"
assert_output_contains "factory-guard.sh"
assert_output_contains '"Bash(gh issue comment *)"'
assert_equal "$before" "$(cksum < "$target/.claude/settings.json")" "expected settings.json unchanged"

# --- main protection ----------------------------------------------------------

begin_case "default run sets main protection after the gh check"
git init -q "$target"
run_install "$target"
assert_status 0
assert_equal "gh repo view --json nameWithOwner -q .nameWithOwner
gh api repos/octo/repo/branches/main/protection
gh api -X PUT repos/octo/repo/branches/main/protection --input -" "$(cat "$gh_log")" \
  "expected the repo lookup, the protection read, then the PUT"
assert_equal "$target" "$(cat "$case_dir/gh-repo-view.cwd" 2> /dev/null)" "expected gh repo view to run in the Target"
assert_equal '{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
  "$(jq -c . "$case_dir/gh-put.json" 2> /dev/null)" "expected the protection JSON"
assert_output_contains "main protection: set (pull request required, no force pushes, no deletions)."
case "$output" in
  *"gh: found"*"main protection: set"*"agent-browser: already installed"*) ;;
  *) fail "expected main protection between the gh check and agent-browser. Output: $output" ;;
esac

begin_case "--protect-main sets main protection and combines with --force in any order"
run_install "$target" --protect-main --force
assert_status 0
assert_output_contains "main protection: set"
assert_output_contains "0 overwritten"

begin_case "--no-protect-main makes no gh call"
run_install "$target" --no-protect-main
assert_status 0
assert_output_contains "main protection: skipped (--no-protect-main)."
assert_equal "" "$(cat "$gh_log")" "expected no gh calls"

begin_case "existing main protection is left unchanged"
fake_gh 0 0
run_install "$target"
assert_status 0
assert_output_contains "main protection: already set, left unchanged."
assert_output_lacks "main protection: set ("
case "$(cat "$gh_log")" in
  *"-X PUT"*) fail "expected no PUT. gh calls: $(cat "$gh_log")" ;;
esac

begin_case "a refused protection PUT warns with gh's error and exits 0"
fake_gh 1 1
run_install "$target"
assert_status 0
assert_output_contains "main protection:"
assert_output_contains "HTTP 403: Resource not accessible by integration"
assert_output_lacks "main protection: set ("
assert_output_contains "agent-browser: already installed"

begin_case "missing gh skips main protection"
rm "$case_dir/bin/gh"
run_install "$target"
assert_status 0
assert_output_lacks "main protection: set"
assert_equal "" "$(cat "$gh_log")" "expected no gh calls"

begin_case "--protect-main with --no-protect-main is rejected before the prompt"
before="$(snapshot "$case_dir")"
run_install "$target" --protect-main --no-protect-main
assert_failed
assert_output_contains "Usage: bash scripts/install-software-factory.sh [--force] [--protect-main | --no-protect-main] [--install-agent-browser]"
assert_output_lacks "Target path:"
assert_equal "$before" "$(snapshot "$case_dir")" "expected nothing to change"

begin_case "--no-protect-main given twice is rejected before the prompt"
run_install "$target" --no-protect-main --no-protect-main
assert_failed
assert_output_lacks "Target path:"

# --- summary ----------------------------------------------------------------

printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
