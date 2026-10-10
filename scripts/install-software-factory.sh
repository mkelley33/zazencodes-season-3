#!/usr/bin/env bash
#
# Install of the software factory Template into a Target directory.
#
# Run: bash scripts/install-software-factory.sh
#
# Prompts for the Target path, then makes an Additive copy: every Template
# file the Target does not have yet is added. Example jobs are never copied,
# and factory/backlog.md is written without its checked items. Nothing that
# already exists in the Target is changed or removed, with one exception: the
# rule that ignores factory/jobs/ is appended to the Target .gitignore.
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

EXAMPLE_JOBS_DIR="factory/jobs"
BACKLOG_PATH="factory/backlog.md"
GITIGNORE_RULE="/$EXAMPLE_JOBS_DIR/"
GITIGNORE_COMMENT="# Software factory job folders are runtime state"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Lists the Template entries to install as paths relative to the Template
# root. Example jobs are left out; the directory that holds them is kept.
# $1 is a find(1) type test: "-type d" for directories, "! -type d" for files.
list_template_entries() {
  # shellcheck disable=SC2086 # $1 is a find expression that must split
  (cd "$template" && find . -mindepth 1 $1 ! -name .DS_Store | sort) \
    | sed -e 's|^\./||' -e "\|^$EXAMPLE_JOBS_DIR/|d"
}

# Prints the Template backlog without its checked items.
backlog_without_checked_items() {
  sed -e '/^[[:space:]]*- \[[xX]\]/d' "$template/$BACKLOG_PATH"
}

# Succeeds when the Target entry has the content the install would write.
has_installed_content() {
  if [ "$1" = "$BACKLOG_PATH" ]; then
    backlog_without_checked_items | cmp -s - "$target/$1"
  else
    cmp -s "$template/$1" "$target/$1"
  fi
}

# Makes the Target .gitignore ignore job folders, which are runtime state.
# Only ever appends: every existing line stays as it is. Sets gitignore_status
# for the report.
ensure_gitignore_rule() {
  local gitignore="$target/.gitignore"

  if [ -L "$gitignore" ] || { [ -e "$gitignore" ] && [ ! -f "$gitignore" ]; }; then
    gitignore_status="skipped, it is not a regular file. Add this line by hand: $GITIGNORE_RULE"
    return
  fi

  if [ ! -e "$gitignore" ]; then
    printf '%s\n%s\n' "$GITIGNORE_COMMENT" "$GITIGNORE_RULE" > "$gitignore"
    gitignore_status="created with $GITIGNORE_RULE"
    return
  fi

  if grep -q -E "^/?$EXAMPLE_JOBS_DIR/?[[:space:]]*\$" "$gitignore"; then
    gitignore_status="already ignores $GITIGNORE_RULE"
    return
  fi

  if [ -s "$gitignore" ]; then
    # A last line without a newline would otherwise be joined with the rule.
    if [ -n "$(tail -c 1 "$gitignore")" ]; then
      printf '\n' >> "$gitignore"
    fi
    printf '\n' >> "$gitignore"
  fi
  printf '%s\n%s\n' "$GITIGNORE_COMMENT" "$GITIGNORE_RULE" >> "$gitignore"
  gitignore_status="updated with $GITIGNORE_RULE"
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
backlog_is_added=false
added_count=0
identical_count=0
different_count=0

while IFS= read -r relative_path; do
  target_entry="$target/$relative_path"
  if [ ! -e "$target_entry" ] && [ ! -L "$target_entry" ]; then
    added="$added  $relative_path"$'\n'
    added_count=$((added_count + 1))
    if [ "$relative_path" = "$BACKLOG_PATH" ]; then
      backlog_is_added=true
    fi
  elif [ -f "$target_entry" ] && has_installed_content "$relative_path"; then
    identical_count=$((identical_count + 1))
  else
    different="$different  $relative_path"$'\n'
    different_count=$((different_count + 1))
  fi
done < <(list_template_entries "! -type d")

# --- copy --------------------------------------------------------------------

# -rl, not -a: -a would rewrite permissions and timestamps on directories the
# Target already has.
rsync -rl --ignore-existing --exclude .DS_Store \
  --exclude "/$EXAMPLE_JOBS_DIR/*" --exclude "/$BACKLOG_PATH" \
  "$template/" "$target/"

if [ "$backlog_is_added" = true ]; then
  backlog_without_checked_items > "$target/$BACKLOG_PATH"
fi

# --- setup -------------------------------------------------------------------

gitignore_status=""
ensure_gitignore_rule

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

printf '\n.gitignore: %s\n' "$gitignore_status"

printf '\nDone: %s added, %s identical, %s different.\n' \
  "$added_count" "$identical_count" "$different_count"
