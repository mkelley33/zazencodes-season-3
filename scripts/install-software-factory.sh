#!/usr/bin/env bash
#
# Install of the software factory Template into a Target directory.
#
# Run: bash scripts/install-software-factory.sh
#      bash scripts/install-software-factory.sh --force
#
# Prompts for the Target path, then makes an Additive copy: every Template
# file the Target does not have yet is added. Nothing that already exists in
# the Target is changed or removed, apart from the Overwrites --force asks for.
#
#   - Skip:      the Target already has an entry at a Template file's path.
#                The entry is left alone and reported as identical or different.
#   - Conflict:  the Target has a symlink or a file where the Template has a
#                directory. Every Conflict is listed and nothing is copied.
#   - Overwrite: with --force, a different Skip that is a regular file (not a
#                symlink) gets the Template file's content. --force never
#                touches directories, symlinks, identical files or entries the
#                Template does not have, and a Conflict still aborts the run.
#
# The last steps check for the gh CLI, which the factory uses to keep each
# Job on a GitHub Issue, and install the agent-browser CLI with Homebrew when
# it is not on the PATH yet.
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
if [ "$#" -eq 1 ] && [ "$1" = "--force" ]; then
  force=true
elif [ "$#" -ne 0 ]; then
  die "Usage: bash scripts/install-software-factory.sh [--force]"
fi

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

while IFS= read -r relative_path; do
  target_entry="$target/$relative_path"
  if [ ! -e "$target_entry" ] && [ ! -L "$target_entry" ]; then
    added="$added  $relative_path"$'\n'
    added_count=$((added_count + 1))
  elif [ -f "$target_entry" ] && cmp -s "$template/$relative_path" "$target_entry"; then
    identical_count=$((identical_count + 1))
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
install_agent_browser
