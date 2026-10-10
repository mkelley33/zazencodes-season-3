#!/usr/bin/env bash
#
# Tests for src/software-factory-claude-code/factory/serve.py, the dashboard
# server that proxies GitHub reads through the gh CLI.
#
# Run: bash scripts/serve.test.sh
#
# Every case starts its own server on a free port with a fake gh on the PATH.
# The fake logs its arguments and answers with a canned `gh api --include`
# response, so no test reaches GitHub. Written for bash 3.2 (the macOS
# default).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE="$SCRIPT_DIR/../src/software-factory-claude-code/factory/serve.py"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
server_pid=""
trap 'stop_server; rm -rf "$WORK"' EXIT

case_count=0
failure_count=0
case_name=""
case_dir=""
call_log=""
port=""
status=""
headers=""
body=""

# --- fixtures ---------------------------------------------------------------

# Starts a new case: a fake gh whose `repo view` answers octo/repo and whose
# `api` call prints the canned response in $case_dir/response and exits with
# the status in $case_dir/exit.
begin_case() {
  stop_server
  case_count=$((case_count + 1))
  case_name="$1"
  case_dir="$WORK/case-$case_count"
  call_log="$case_dir/calls.log"
  mkdir -p "$case_dir/bin"
  : > "$call_log"
  printf '0\n' > "$case_dir/exit"
  gh_answers 200 '[{"number":1}]'
  cat > "$case_dir/bin/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1" in
  repo) printf 'octo/repo\n' ;;
  api) cat "$FAKE_GH_RESPONSE"; printf '%s\n' "$FAKE_GH_STDERR" >&2; exit "$(cat "$FAKE_GH_EXIT")" ;;
esac
FAKE
  chmod +x "$case_dir/bin/gh"
}

# Makes the fake gh api answer with HTTP status $1, body $2, and the optional
# extra header lines in $3 (each terminated with CRLF by the caller).
gh_answers() {
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json; charset=utf-8\r\nX-RateLimit-Remaining: 4999\r\n%s\r\n%s' \
    "$1" "${3:-}" "$2" > "$case_dir/response"
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Starts serve.py with the extra arguments given, on a free port, and waits
# until it answers. $server_output collects what it printed.
start_server() {
  port="$(free_port)"
  server_output="$case_dir/server.log"
  (
    cd "$case_dir" && env PATH="$case_dir/bin:/usr/bin:/bin" \
      FAKE_GH_LOG="$call_log" FAKE_GH_RESPONSE="$case_dir/response" \
      FAKE_GH_EXIT="$case_dir/exit" FAKE_GH_STDERR="${fake_gh_stderr:-}" \
      python3 -I "$SERVE" --port "$port" "$@" > "$server_output" 2>&1
  ) &
  server_pid=$!
  local tries=0
  until curl -s -o /dev/null "http://127.0.0.1:$port/" || [ "$tries" -ge 50 ]; do
    if ! kill -0 "$server_pid" 2> /dev/null; then
      return 1
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  # Keep the startup calls apart, so cases assert only on their own requests.
  cp "$call_log" "$case_dir/startup.log"
  : > "$call_log"
}

stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2> /dev/null
    wait "$server_pid" 2> /dev/null
    server_pid=""
  fi
}

# Requests $1 (a path) with the extra curl arguments that follow. Sets
# $status, $headers and $body.
request() {
  local path="$1"
  shift
  curl -s --path-as-is -D "$case_dir/headers" -o "$case_dir/body" \
    -w '%{http_code}' "http://127.0.0.1:$port$path" "$@" > "$case_dir/status"
  status="$(cat "$case_dir/status")"
  headers="$(tr -d '\r' < "$case_dir/headers")"
  body="$(cat "$case_dir/body")"
}

# --- assertions -------------------------------------------------------------

fail() {
  failure_count=$((failure_count + 1))
  printf 'FAIL: %s\n      %s\n' "$case_name" "$1"
}

assert_status() {
  [ "$status" = "$1" ] || fail "expected HTTP $1, got $status. Body: $body"
}

assert_body_contains() {
  case "$body" in
    *"$1"*) ;;
    *) fail "expected body to contain '$1'. Body: $body" ;;
  esac
}

assert_body_equal() {
  [ "$body" = "$1" ] || fail "expected body '$1', got '$body'"
}

assert_header() {
  case "$headers" in
    *"$1"*) ;;
    *) fail "expected a '$1' header. Headers: $headers" ;;
  esac
}

assert_calls() {
  [ "$(cat "$call_log")" = "$1" ] || fail "expected gh calls:
$1
got:
$(cat "$call_log")"
}

# --- cases ------------------------------------------------------------------

begin_case "/ serves the dashboard"
start_server
request "/"
assert_status 200
assert_body_contains "<!doctype html>"
assert_calls ""

begin_case "startup asks gh for the repository once and /api/repo answers it"
start_server
[ "$(cat "$case_dir/startup.log")" = "repo view --json nameWithOwner -q .nameWithOwner" ] \
  || fail "expected one gh repo view call at startup, got: $(cat "$case_dir/startup.log")"
request "/api/repo"
assert_status 200
assert_body_equal '{"nameWithOwner": "octo/repo"}'
assert_header "Cache-Control: no-store"
assert_header "Content-Type: application/json"
assert_calls ""

begin_case "--repo skips the gh repository lookup"
rm "$case_dir/bin/gh"
start_server --repo someone/elsewhere
request "/api/repo"
assert_status 200
assert_body_equal '{"nameWithOwner": "someone/elsewhere"}'

begin_case "startup without gh and without --repo fails with a clear message"
rm "$case_dir/bin/gh"
if start_server; then
  fail "expected the server not to start"
fi
wait "$server_pid" 2> /dev/null
server_pid=""
grep -q "gh" "$server_output" || fail "expected the message to mention gh. Output: $(cat "$server_output")"
grep -q -- "--repo" "$server_output" || fail "expected the message to mention --repo. Output: $(cat "$server_output")"

begin_case "/api/<path> forwards the path and query to gh api"
start_server
request "/api/issues?state=open&labels=factory&per_page=100"
assert_status 200
assert_body_equal '[{"number":1}]'
assert_header "Cache-Control: no-store"
assert_header "Content-Type: application/json"
assert_header "X-RateLimit-Remaining: 4999"
assert_calls "api --include repos/octo/repo/issues?state=open&labels=factory&per_page=100"

begin_case "nested paths reach gh api unchanged"
start_server
request "/api/issues/42/comments?per_page=100"
assert_status 200
assert_calls "api --include repos/octo/repo/issues/42/comments?per_page=100"

begin_case "If-None-Match is passed to gh api and 304 comes back empty"
gh_answers 304 '' $'ETag: "abc"\r\n'
printf '1\n' > "$case_dir/exit"
start_server
request "/api/issues" -H 'If-None-Match: "abc"'
assert_status 304
assert_body_equal ""
assert_header 'ETag: "abc"'
assert_calls 'api --include repos/octo/repo/issues -H If-None-Match: "abc"'

begin_case "ETag from GitHub is forwarded"
gh_answers 200 '[]' $'ETag: "xyz"\r\n'
start_server
request "/api/issues"
assert_status 200
assert_header 'ETag: "xyz"'

begin_case "gh api error status is forwarded as JSON"
gh_answers 404 '{"message":"Not Found"}'
printf '1\n' > "$case_dir/exit"
fake_gh_stderr="gh: Not Found (HTTP 404)"
start_server
fake_gh_stderr=""
request "/api/issues/999"
assert_status 404
assert_body_contains '"error"'
assert_body_contains "Not Found"
assert_header "Cache-Control: no-store"

begin_case "gh output without an HTTP status is a 502"
printf 'garbage\n' > "$case_dir/response"
printf '1\n' > "$case_dir/exit"
start_server
request "/api/issues"
assert_status 502
assert_body_contains '"error"'

begin_case "path with .. is rejected before gh runs"
start_server
request "/api/../secret"
assert_status 400
assert_calls ""

begin_case "path with unexpected characters is rejected before gh runs"
start_server
request "/api/issues;id"
assert_status 400
assert_calls ""

begin_case "query with unexpected characters is rejected before gh runs"
start_server
request "/api/issues?state=open;rm"
assert_status 400
assert_calls ""

begin_case "empty api path is rejected"
start_server
request "/api/"
assert_status 400
assert_calls ""

begin_case "missing gh at request time is a 503"
start_server --repo octo/repo
rm "$case_dir/bin/gh"
request "/api/issues"
assert_status 503
assert_body_contains '"error"'
assert_header "Cache-Control: no-store"

begin_case "non-GET requests are refused without calling gh"
start_server
request "/api/issues" -X POST -d '{}'
case "$status" in
  405|501) ;;
  *) fail "expected HTTP 405 or 501 for POST, got $status" ;;
esac
assert_calls ""

begin_case "other files in the factory folder are served as static files"
start_server
request "/dashboard.html"
assert_status 200
assert_body_contains "<!doctype html>"

# --- summary ----------------------------------------------------------------

stop_server
printf '%s cases, %s failed assertions\n' "$case_count" "$failure_count"
[ "$failure_count" -eq 0 ]
