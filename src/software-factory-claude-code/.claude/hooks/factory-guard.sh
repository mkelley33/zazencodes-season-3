#!/usr/bin/env bash
#
# The factory Guard: a PreToolUse hook on the Bash tool that blocks the
# commands which would land work on main without a pull request.
#
#   - git merge                       (git merge-base, merge-tree, mergetool pass)
#   - gh pr merge
#   - git push to main                (main, +main, :main, <x>:main, refs/heads/main)
#   - git push --force, -f, --force-with-lease[=<...>]
#   - git branch -D, git branch --delete --force
#   - git commit while the branch is main, read in the directory the earlier
#     `cd <dir>`s in the command lead to from the session's cwd
#
# A command matches only at a command boundary: the start of the string, or
# after &&, ||, ;, |, ( or a newline outside quotes. Heredoc bodies are skipped,
# so a review comment that quotes `git push --force` passes.
#
# Reads the hook JSON on stdin. Exit 2 blocks the call and the one stderr line
# tells the agent why. Exit 0 allows it. Input it cannot parse is allowed:
# GitHub branch protection on main is the backstop.
#
# Bash 3.2, sed and git only, so it runs in every Target with no JSON tool.

# Bytes, not characters: every character that matters here is ASCII.
export LC_ALL=C

bs='\'
soh=$'\001'

# Prints the JSON string value of key $1 in $input, with the escapes a shell
# command can carry undone: \\ \" \n \t \/. sed, not bash substitution, which
# is quadratic in bash 3.2 and would stall on a long heredoc.
json_field() {
  printf '%s\n' "$input" \
    | sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
    | sed -e 's/\\\\/'"$soh"'/g' -e 's/\\"/"/g' -e 's/\\t/'$'\t''/g' -e 's|\\/|/|g' \
      -e 's/\\n/\'$'\n''/g' -e 's/'"$soh"'/\\/g'
}

block() {
  printf 'factory-guard: %s is blocked. Land changes through a pull request that a human merges on GitHub.\n' "$1" >&2
  exit 2
}

# Raw newlines in JSON only sit between tokens, so joining lines is safe.
input="$(tr '\n' ' ')"
command="$(json_field command)"
[ -n "$command" ] || exit 0
cwd="$(json_field cwd)"

# --- split the command into simple commands ----------------------------------

segments=()
segment=""
quote=""        # the open quote character, if any
heredoc=""      # delimiter of a heredoc whose body starts on the next line
body_end=""     # delimiter that ends the heredoc body being skipped
heredoc_re="^-?[[:space:]]*[\"']?([A-Za-z0-9_]+)"
plain_re="^[^\"'$bs;&|(<]+" # a run of characters that never change the state

end_segment() {
  segments[${#segments[@]}]="$segment"
  segment=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$body_end" ]; then
    [ "${line#"${line%%[!$'\t']*}"}" = "$body_end" ] && body_end=""
    continue
  fi

  continued=false
  i=0
  n=${#line}
  while [ "$i" -lt "$n" ]; do
    if [[ ${line:i} =~ $plain_re ]]; then
      segment="$segment${BASH_REMATCH[0]}"
      i=$((i + ${#BASH_REMATCH[0]}))
      continue
    fi
    c="${line:i:1}"
    if [ "$quote" = "'" ]; then
      [ "$c" = "'" ] && quote=""
      segment="$segment$c"
    elif [ "$c" = "$bs" ]; then
      [ "$((i + 1))" -eq "$n" ] && [ -z "$quote" ] && continued=true
      segment="$segment$c${line:i+1:1}"
      i=$((i + 1))
    elif [ "$c" = '<' ] && [ "${line:i:2}" = '<<' ] && [ "${line:i+2:1}" != '<' ] \
      && [ -z "$heredoc" ] && [[ ${line:i+2} =~ $heredoc_re ]]; then
      # Also inside double quotes, for "$(cat <<'EOF' ... EOF)".
      heredoc="${BASH_REMATCH[1]}"
      segment="$segment<<"
      i=$((i + 1))
    elif [ "$quote" = '"' ]; then
      [ "$c" = '"' ] && quote=""
      segment="$segment$c"
    else
      case "$c" in
        "'" | '"') quote="$c"; segment="$segment$c" ;;
        ';' | '&' | '|' | '(') end_segment ;;
        *) segment="$segment$c" ;;
      esac
    fi
    i=$((i + 1))
  done

  if [ "$continued" = true ]; then
    segment="${segment%"$bs"}"
  elif [ -n "$quote" ]; then
    segment="$segment"$'\n'
  else
    end_segment
  fi
  if [ -n "$heredoc" ]; then
    body_end="$heredoc"
    heredoc=""
  fi
done <<< "$command"
end_segment

# --- check each simple command -----------------------------------------------

cd_args=()

for segment in "${segments[@]}"; do
  words=()
  read -r -a words <<< "$segment"
  [ "${#words[@]}" -gt 0 ] || continue

  case "${words[0]} ${words[1]:-}" in
    "cd "?*)
      dir="${segment#*cd}"
      dir="${dir#"${dir%%[![:space:]]*}"}"
      dir="${dir%"${dir##*[![:space:]]}"}"
      case "$dir" in
        \"*\" | \'*\') dir="${dir:1:${#dir}-2}" ;;
      esac
      case "$dir" in
        "~") dir="$HOME" ;;
        "~/"*) dir="$HOME/${dir#\~/}" ;;
      esac
      [ "$dir" = "-" ] || cd_args[${#cd_args[@]}]="$dir"
      ;;
    "git merge")
      block "git merge"
      ;;
    "gh pr")
      [ "${words[2]:-}" = merge ] && block "gh pr merge"
      ;;
    "git push")
      for word in "${words[@]:2}"; do
        case "$word" in
          --force | -f | --force-with-lease | --force-with-lease=*) block "git push --force" ;;
          -*) ;;
          *)
            ref="${word#+}"
            ref="${ref##*:}"
            [ "$ref" = main ] || [ "$ref" = refs/heads/main ] && block "git push to main"
            ;;
        esac
      done
      ;;
    "git branch")
      delete=false
      force=false
      for word in "${words[@]:2}"; do
        case "$word" in
          -D) block "git branch -D" ;;
          -d | --delete) delete=true ;;
          -f | --force) force=true ;;
        esac
      done
      [ "$delete" = true ] && [ "$force" = true ] && block "git branch -D"
      ;;
    "git commit")
      git_args=(-C "$cwd")
      for dir in ${cd_args[@]+"${cd_args[@]}"}; do
        git_args[${#git_args[@]}]=-C
        git_args[${#git_args[@]}]="$dir"
      done
      branch="$(git "${git_args[@]}" branch --show-current 2> /dev/null)"
      [ "$branch" = main ] && block "git commit on main"
      ;;
  esac
done

exit 0
