#!/usr/bin/env bash
#
# Additive copy of the software factory Template into a Target directory.
#
# Run: bash scripts/copy-software-factory.sh
#
# Prompts for the Target path, then adds every Template file the Target does
# not have yet. Nothing that already exists in the Target is changed or
# removed:
#
#   - Skip:     the Target already has an entry at a Template file's path.
#               The entry is left alone and reported as identical or different.
#   - Conflict: the Target has a symlink or a file where the Template has a
#               directory. Every Conflict is listed and nothing is copied.
#
# See CONTEXT.md for the terms. Written for bash 3.2 (the macOS default).
#
# SOFTWARE_FACTORY_TEMPLATE_DIR overrides the Template location (used by the
# tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SOFTWARE_FACTORY_TEMPLATE_DIR:-$SCRIPT_DIR/../src/software-factory-claude-code}"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Lists Template entries as paths relative to the Template root.
# $1 is a find(1) type test: "-type d" for directories, "! -type d" for files.
list_template_entries() {
  # shellcheck disable=SC2086 # $1 is a find expression that must split
  (cd "$template" && find . -mindepth 1 $1 ! -name .DS_Store | sort) | sed 's|^\./||'
}

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
added_count=0
identical_count=0
different_count=0

while IFS= read -r relative_path; do
  target_entry="$target/$relative_path"
  if [ ! -e "$target_entry" ] && [ ! -L "$target_entry" ]; then
    added="$added  $relative_path"$'\n'
    added_count=$((added_count + 1))
  elif [ -f "$target_entry" ] && cmp -s "$template/$relative_path" "$target_entry"; then
    identical_count=$((identical_count + 1))
  else
    different="$different  $relative_path"$'\n'
    different_count=$((different_count + 1))
  fi
done < <(list_template_entries "! -type d")

# --- copy --------------------------------------------------------------------

# -rl, not -a: -a would rewrite permissions and timestamps on directories the
# Target already has.
rsync -rl --ignore-existing --exclude .DS_Store "$template/" "$target/"

# --- report ------------------------------------------------------------------

printf '\nTemplate: %s\nTarget:   %s\n' "$template" "$target"

if [ "$added_count" -gt 0 ]; then
  printf '\nAdded (%s):\n%s' "$added_count" "$added"
fi

printf '\nSkipped, identical content: %s\n' "$identical_count"

if [ "$different_count" -gt 0 ]; then
  printf '\nSkipped, different content (%s). Left unchanged, compare by hand:\n%s' \
    "$different_count" "$different"
fi

printf '\nDone: %s added, %s identical, %s different.\n' \
  "$added_count" "$identical_count" "$different_count"
