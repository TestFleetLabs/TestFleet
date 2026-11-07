#!/bin/sh
# Starts a TestFleet run and waits for it, printing its log as it goes.
#
#   testfleet-run.sh <project> <test-definition> <environment> [tag]
#
# With a tag, the test definition's image tag is updated first, so this run and
# every scheduled run after it use the matching E2E image.
#
# Environment: TESTFLEET_URL (https://testfleet.example.internal), TESTFLEET_TOKEN
# (an API token from Settings), TESTFLEET_POLL_SECONDS (default 5).
# Needs curl and jq.
#
# The run records what was deployed, shown on its page and in notifications:
# TESTFLEET_DEPLOYMENT_VERSION (default: the tag), TESTFLEET_DEPLOYMENT_COMMIT and
# TESTFLEET_DEPLOYMENT_URL (default: the commit and the pipeline run of GitHub
# Actions, GitLab CI, Azure Pipelines, or Jenkins).
#
# Exit status: 0 when the run passed, 1 when its tests failed, 2 for everything
# else (error, timeout, cancelled, or a refused request).
set -eu

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  echo "usage: $0 <project> <test-definition> <environment> [tag]" >&2
  exit 2
fi

project=$1
test_definition=$2
environment=$3
tag=${4:-}

base="${TESTFLEET_URL:?set TESTFLEET_URL}/api/v1"
auth="Authorization: Bearer ${TESTFLEET_TOKEN:?set TESTFLEET_TOKEN}"
poll=${TESTFLEET_POLL_SECONDS:-5}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# api METHOD PATH [JSON]: prints the response body; fails on an error response.
# Call it as `x=$(api …)`, never in a pipeline: its exit status must reach `set -e`.
api() {
  if [ $# -eq 3 ]; then
    code=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$1" -H "$auth" \
      -H 'Content-Type: application/json' --data "$3" "$base$2")
  else
    code=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$1" -H "$auth" "$base$2")
  fi

  case $code in
    2??) cat "$tmp/body" ;;
    *)
      message=$(jq -r '.error.message // empty' "$tmp/body" 2>/dev/null || true)
      details=$(jq -r '.error.details // empty | to_entries[] | "  \(.key) \(.value | join(", "))"' "$tmp/body" 2>/dev/null || true)
      echo "TestFleet answered $code: ${message:-$(cat "$tmp/body")}" >&2
      if [ -n "$details" ]; then echo "$details" >&2; fi
      exit 2
      ;;
  esac
}

if [ -n "$tag" ]; then
  definition=$(api PATCH "/projects/$project/test-definitions/$test_definition" \
    "$(jq -n --arg tag "$tag" '{tag: $tag}')")
  echo "TestFleet: $test_definition now uses $(echo "$definition" | jq -r .image)"
fi

# What was deployed. A commit found in the CI system's variables is only sent when it
# looks like a commit hash, so an unexpected value never keeps the tests from running.
version=${TESTFLEET_DEPLOYMENT_VERSION:-$tag}
commit=${TESTFLEET_DEPLOYMENT_COMMIT:-}
if [ -z "$commit" ]; then
  commit=${GITHUB_SHA:-${CI_COMMIT_SHA:-${BUILD_SOURCEVERSION:-${GIT_COMMIT:-}}}}
  case $commit in
    *[!0-9a-fA-F]*) commit= ;;
    ???????*) ;;
    *) commit= ;;
  esac
fi
url=${TESTFLEET_DEPLOYMENT_URL:-}
if [ -z "$url" ]; then
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
  elif [ -n "${CI_PIPELINE_URL:-}" ]; then
    url=$CI_PIPELINE_URL
  elif [ -n "${BUILD_BUILDID:-}" ] && [ -n "${SYSTEM_COLLECTIONURI:-}" ]; then
    url="${SYSTEM_COLLECTIONURI}${SYSTEM_TEAMPROJECTID:-}/_build/results?buildId=$BUILD_BUILDID"
  elif [ -n "${BUILD_URL:-}" ]; then
    url=$BUILD_URL
  fi
fi

run=$(api POST "/projects/$project/runs" \
  "$(jq -n --arg t "$test_definition" --arg e "$environment" \
    --arg version "$version" --arg commit "$commit" --arg url "$url" '
    {test_definition: $t, environment: $e}
    + ({version: $version, commit: $commit, url: $url} | with_entries(select(.value != ""))
       | if . == {} then {} else {deployment: .} end)')")
run_id=$(echo "$run" | jq -r .id)
echo "TestFleet: run $run_id of $(echo "$run" | jq -r .image) on $environment"
echo "TestFleet: $(echo "$run" | jq -r .url)"

# Prints the log lines stored since the last call.
sequence=0
print_log() {
  code=$(curl -sS -o "$tmp/log" -D "$tmp/headers" -w '%{http_code}' -H "$auth" \
    "$base/runs/$run_id/log?after=$sequence")

  if [ "$code" = 200 ]; then
    cat "$tmp/log"
    next=$(tr -d '\r' <"$tmp/headers" | awk -F': ' 'tolower($1) == "testfleet-log-sequence" { print $2 }')
    if [ -n "$next" ]; then sequence=$next; fi
  fi
}

while :; do
  print_log
  run=$(api GET "/runs/$run_id")
  if [ "$(echo "$run" | jq -r .final)" = true ]; then break; fi
  sleep "$poll"
done

# Lines stored between the last log request and the end of the run
print_log

status=$(echo "$run" | jq -r .status)
echo "TestFleet: run $run_id $status$(echo "$run" | jq -r '
  if .tests then " (\(.tests.passed) passed, \(.tests.failed) failed, \(.tests.skipped) skipped)"
  elif .error_message then ": \(.error_message)"
  else "" end')"

case $status in
  passed) exit 0 ;;
  failed) exit 1 ;;
  *) exit 2 ;;
esac
