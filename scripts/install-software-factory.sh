#!/usr/bin/env bash
#
# Install of the software factory Template into a Target directory.
#
# Run: bash scripts/install-software-factory.sh
#      bash scripts/install-software-factory.sh [--force] [--protect-main | --no-protect-main]
#
# Prompts for the Target path, then makes an Additive copy: every Template
# file the Target does not have yet is added. Nothing that already exists in
# the Target is changed or removed, apart from the Overwrites --force asks for
# and the Hook merge.
#
#   - Skip:       the Target already has an entry at a Template file's path.
#                 The entry is left alone and reported as identical or different.
#   - Conflict:   the Target has a symlink or a file where the Template has a
#                 directory. Every Conflict is listed and nothing is copied.
#   - Overwrite:  with --force, a different Skip that is a regular file (not a
#                 symlink) gets the Template file's content. --force never
#                 touches directories, symlinks, identical files or entries the
#                 Template does not have, and a Conflict still aborts the run.
#   - Hook merge: a different .claude/settings.json is never Overwritten.
#                 Instead jq adds the Template's PreToolUse hooks (the Guard)
#                 and appends its permissions.allow rules (the factory's
#                 gh issue comment and gh issue edit) that the file lacks,
#                 keeping its own rules first and every other key as it was.
#                 It names each rule it added, since those commands then run
#                 without a prompt. Without jq, or when the file is not valid JSON, it stays as
#                 it is and the Template's settings are printed to add by hand.
#
# The last steps check for the gh CLI, which the factory uses to keep each
# Job on a GitHub Issue, protect the Target's main branch on GitHub, and
# install the agent-browser CLI with Homebrew when it is not on the PATH yet.
# Main protection (on by default, --protect-main) requires a pull request
# before merging and refuses force pushes and deletion. Protection that is
# already set is left alone. --no-protect-main skips the step.
#
# See CONTEXT.md for the terms. Written for bash 3.2 (the macOS default).
#
# SOFTWARE_FACTORY_TEMPLATE_DIR overrides the Template location (used by the
# tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SOFTWARE_FACTORY_TEMPLATE_DIR:-$SCRIPT_DIR/../src/software-factory-claude-code}"

AGENT_BROWSER_URL="https://github.com/vercel-labs/agent-browser#installation"
GH_URL="https://cli.github.com"
USAGE="Usage: bash scripts/install-software-factory.sh [--force] [--protect-main | --no-protect-main]"
SETTINGS=".claude/settings.json"

# Appends each Template PreToolUse entry ($template[0]) that the settings do
# not run yet, matched by hook command, and each Template permissions.allow
# rule they lack, matched by exact string. Run with jq -er: it prints what was
# added on the first line, the added rules on the second (empty when there are
# none) and the merged settings below them, or false when nothing is missing.
HOOK_MERGE_FILTER='
  [.hooks.PreToolUse[]?.hooks[]?.command] as $commands
  | (.permissions.allow // []) as $rules
  | [$template[0].hooks.PreToolUse[]
      | select(any(.hooks[].command; . as $c | any($commands[]; . == $c)) | not)] as $missing_hooks
  | [$template[0].permissions.allow[]
      | select(. as $r | any($rules[]; . == $r) | not)] as $missing_rules
  | if ($missing_hooks + $missing_rules | length) == 0 then false
    else
      ([if ($missing_hooks | length) > 0 then "the Guard" else empty end,
        if ($missing_rules | length) > 0 then "the permission rules" else empty end]
        | join(" and ")),
      (if ($missing_rules | length) == 0 then ""
       elif ($missing_rules | length) == 1 then "this rule now runs without a prompt: \($missing_rules[0])"
       else "these rules now run without a prompt: \($missing_rules | join(", "))" end),
      (if ($missing_hooks | length) > 0
         then .hooks.PreToolUse = ((.hooks.PreToolUse // []) + $missing_hooks) else . end
       | if ($missing_rules | length) > 0
           then .permissions.allow = ($rules + $missing_rules) else . end)
    end'

# A pull request is required before merging into main, for admins too, with
# no approving review required, so the owner can still merge their own PR.
MAIN_PROTECTION='{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Lists the Template entries to install as paths relative to the Template
# root. $1 is a find(1) type test: "-type d" for directories, "! -type d" for
# files.
list_template_entries() {
  # shellcheck disable=SC2086 # $1 is a find expression that must split
  (cd "$template" && find . -mindepth 1 $1 ! -name .DS_Store | sort) \
    | sed -e 's|^\./||'
}

# Warns when the gh CLI is missing. The factory needs it to open, read and
# close the GitHub Issue that records each Job. Never fails the install.
check_gh() {
  if command -v gh > /dev/null 2>&1; then
    printf 'gh: found.\n'
    return 0
  fi

  printf 'gh: not installed. The factory needs it to track Jobs as GitHub Issues. Install it and run gh auth login: %s\n' \
    "$GH_URL" >&2
  return 0
}

# Adds the Guard and the factory's permission rules to the Target's own
# .claude/settings.json. Leaves the file byte-identical when both are already
# there, when jq is missing, or when jq cannot merge it; the last two print
# the Template's settings to add by hand. Never fails the install.
hook_merge() {
  local merged
  local added
  local rules
  local jq_status=0

  if ! command -v jq > /dev/null 2>&1; then
    printf 'Hook merge: jq was not found, so %s was left unchanged. Add the hooks and permission rules below to it by hand:\n' \
      "$SETTINGS" >&2
    cat "$template/$SETTINGS" >&2
    return 0
  fi

  merged="$(jq -er --slurpfile template "$template/$SETTINGS" "$HOOK_MERGE_FILTER" \
    "$target/$SETTINGS" 2> /dev/null)" || jq_status=$?
  case "$jq_status" in
    0)
      added="${merged%%$'\n'*}"
      merged="${merged#*$'\n'}"
      rules="${merged%%$'\n'*}"
      printf '%s\n' "${merged#*$'\n'}" > "$target/$SETTINGS"
      printf 'Hook merge: added %s to %s.\n' "$added" "$SETTINGS"
      if [ -n "$rules" ]; then
        printf 'Hook merge: %s.\n' "$rules"
      fi
      ;;
    1)
      printf 'Hook merge: %s already has the Guard and the permission rules.\n' "$SETTINGS"
      ;;
    *)
      printf 'Hook merge: could not merge the Guard and the permission rules into %s (is it valid JSON?), so it was left unchanged. Add the hooks and permission rules below to it by hand:\n' \
        "$SETTINGS" >&2
      cat "$template/$SETTINGS" >&2
      ;;
  esac
  return 0
}

# Protects main on the Target's GitHub repo, so even a command that slips
# past the Guard cannot land on it. Existing protection is left alone: the
# PUT replaces all of it, status checks included. Never fails the install.
protect_main() {
  local repo
  local errors

  if [ "$protect_main" = false ]; then
    printf 'main protection: skipped (--no-protect-main).\n'
    return 0
  fi
  if ! command -v gh > /dev/null 2>&1; then
    printf 'main protection: skipped (gh not installed).\n'
    return 0
  fi

  errors="$(mktemp)"
  if ! repo="$(cd "$target" && gh repo view --json nameWithOwner -q .nameWithOwner 2> "$errors")"; then
    protect_main_failed "$errors"
  elif gh api "repos/$repo/branches/main/protection" > /dev/null 2> "$errors"; then
    printf 'main protection: already set, left unchanged.\n'
  elif gh api -X PUT "repos/$repo/branches/main/protection" --input - \
    <<< "$MAIN_PROTECTION" > /dev/null 2> "$errors"; then
    printf 'main protection: set (pull request required, no force pushes, no deletions).\n'
  else
    protect_main_failed "$errors"
  fi
  rm -f "$errors"
  return 0
}

# Warns with the last line gh printed on stderr, saved in the file $1.
protect_main_failed() {
  printf 'main protection: not set (%s). Protect main by hand in the repo settings on GitHub.\n' \
    "$(tail -n 1 "$1")" >&2
}

# Installs the agent-browser CLI that the builder and the UI and UX reviewers
# drive. It is machine-wide, so the step does nothing once it is on the PATH.
# Homebrew keeps it reachable whichever Node version a Target pins; a global
# npm install would be tied to one Node version.
install_agent_browser() {
  if command -v agent-browser > /dev/null 2>&1; then
    printf 'agent-browser: already installed.\n'
    return 0
  fi

  if ! command -v brew > /dev/null 2>&1; then
    printf 'agent-browser: not installed, and Homebrew was not found. Install it by hand: %s\n' \
      "$AGENT_BROWSER_URL" >&2
    return 0
  fi

  printf 'agent-browser: installing with Homebrew.\n'
  if brew install agent-browser && agent-browser install; then
    printf 'agent-browser: installed.\n'
    return 0
  fi

  printf 'agent-browser: install failed. The copy above is complete. Install it by hand: %s\n' \
    "$AGENT_BROWSER_URL" >&2
  return 1
}

force=false
protect_main=""
for arg in "$@"; do
  case "$arg" in
    --force)
      [ "$force" = false ] || die "$USAGE"
      force=true
      ;;
    --protect-main | --no-protect-main)
      [ -z "$protect_main" ] || die "$USAGE"
      if [ "$arg" = --protect-main ]; then protect_main=true; else protect_main=false; fi
      ;;
    *) die "$USAGE" ;;
  esac
done
protect_main="${protect_main:-true}"

command -v rsync > /dev/null 2>&1 || die "rsync is required but was not found."
[ -d "$TEMPLATE_DIR" ] || die "Template does not exist: $TEMPLATE_DIR"
template="$(cd "$TEMPLATE_DIR" && pwd -P)"

# --- read and validate the Target -------------------------------------------

input=""
printf 'Target path: '
IFS= read -r input || true

[ -n "$input" ] || die "No Target path given."

case "$input" in
  "~") input="$HOME" ;;
  "~/"*) input="$HOME/${input#\~/}" ;;
esac

[ -d "$input" ] || die "Target does not exist or is not a directory: $input"
target="$(cd "$input" && pwd -P)"

case "$target/" in
  "$template/"*) die "Target must not be the Template or a directory inside it: $target" ;;
esac

if ! git -C "$target" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  printf 'Warning: Target is not a git repository. The factory needs git to run.\n' >&2
fi

# --- preflight: find every Conflict before anything is written --------------

conflicts=""
while IFS= read -r relative_path; do
  target_entry="$target/$relative_path"
  if [ -L "$target_entry" ]; then
    conflicts="$conflicts  $relative_path (symlink)"$'\n'
  elif [ -e "$target_entry" ] && [ ! -d "$target_entry" ]; then
    conflicts="$conflicts  $relative_path (file)"$'\n'
  fi
done < <(list_template_entries "-type d")

if [ -n "$conflicts" ]; then
  printf 'Conflict: the Target has a symlink or a file where the Template has a directory:\n' >&2
  printf '%s' "$conflicts" >&2
  die "Nothing was copied. Resolve each Conflict in $target, then run again."
fi

# --- classify every Template file -------------------------------------------

added=""
different=""
overwritten=""
added_count=0
identical_count=0
different_count=0
overwritten_count=0
merge_settings=false

while IFS= read -r relative_path; do
  target_entry="$target/$relative_path"
  if [ ! -e "$target_entry" ] && [ ! -L "$target_entry" ]; then
    added="$added  $relative_path"$'\n'
    added_count=$((added_count + 1))
  elif [ -f "$target_entry" ] && cmp -s "$template/$relative_path" "$target_entry"; then
    identical_count=$((identical_count + 1))
  elif [ "$relative_path" = "$SETTINGS" ] && [ -f "$target_entry" ] && [ ! -L "$target_entry" ]; then
    # The Target's own settings: a Hook merge, never an Overwrite.
    different="$different  $relative_path (apart from the Hook merge above)"$'\n'
    different_count=$((different_count + 1))
    merge_settings=true
  elif [ "$force" = true ] && [ -f "$target_entry" ] && [ ! -L "$target_entry" ]; then
    overwritten="$overwritten  $relative_path"$'\n'
    overwritten_count=$((overwritten_count + 1))
  else
    different="$different  $relative_path"$'\n'
    different_count=$((different_count + 1))
  fi
done < <(list_template_entries "! -type d")

# --- copy --------------------------------------------------------------------

# -rl, not -a: -a would rewrite permissions and timestamps on directories the
# Target already has.
rsync -rl --ignore-existing --exclude .DS_Store "$template/" "$target/"

# Then each Overwrite. cp writes into the existing file, so its directory is
# not touched and the file keeps its permissions.
while IFS= read -r line; do
  relative_path="${line#  }"
  cp "$template/$relative_path" "$target/$relative_path"
done < <(printf '%s' "$overwritten")

if [ "$merge_settings" = true ]; then
  hook_merge
fi

# --- report ------------------------------------------------------------------

printf '\nTemplate: %s\nTarget:   %s\n' "$template" "$target"

if [ "$added_count" -gt 0 ]; then
  printf '\nAdded (%s):\n%s' "$added_count" "$added"
fi

printf '\nSkipped, identical content: %s\n' "$identical_count"

if [ "$overwritten_count" -gt 0 ]; then
  printf '\nOverwritten (%s):\n%s' "$overwritten_count" "$overwritten"
fi

if [ "$different_count" -gt 0 ]; then
  printf '\nSkipped, different content (%s). Left unchanged, compare by hand:\n%s' \
    "$different_count" "$different"
fi

if [ "$force" = true ]; then
  printf '\nDone: %s added, %s identical, %s different, %s overwritten.\n' \
    "$added_count" "$identical_count" "$different_count" "$overwritten_count"
else
  printf '\nDone: %s added, %s identical, %s different.\n' \
    "$added_count" "$identical_count" "$different_count"
fi

# --- tools -------------------------------------------------------------------

# Last, so a failed download cannot hide the report above.
printf '\n'
check_gh
protect_main
install_agent_browser
