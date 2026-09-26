#!/bin/sh
# Behaves according to SPIKE_MODE; see .specs/execution-spike-spec.md, section 9.
set -u

artifacts="${TestFleet_ARTIFACTS_DIR:-/TestFleet/artifacts}"

write_artifacts() {
  mkdir -p "$artifacts/reports"
  echo "run $TestFleet_RUN_ID" > "$artifacts/summary.txt"
  echo "<html><body>report</body></html>" > "$artifacts/reports/index.html"
}

tick_forever() {
  i=0
  while true; do
    i=$((i + 1))
    echo "tick $i"
    sleep 1
  done
}

case "${SPIKE_MODE:-pass}" in
  pass)
    echo "starting suite"
    echo "a warning" >&2
    write_artifacts
    echo "all tests passed"
    exit 0
    ;;
  fail)
    echo "starting suite"
    echo "test failed: expected 200, got 500" >&2
    write_artifacts
    exit 1
    ;;
  no_artifacts)
    echo "nothing to keep"
    exit 0
    ;;
  hang)
    # PID 1 ignores signals it has no handler for, so SIGTERM needs an explicit trap.
    trap 'echo "terminated"; exit 143' TERM
    write_artifacts
    tick_forever
    ;;
  ignore_term)
    trap '' TERM
    write_artifacts
    tick_forever
    ;;
  chatty)
    seq 1 50000 | sed 's/^/line /'
    head -c 40000 /dev/zero | tr '\0' 'x'
    echo
    seq 50001 100000 | sed 's/^/line /'
    exit 0
    ;;
  partial)
    printf 'no newline'
    sleep 1
    printf ' at all'
    exit 0
    ;;
  oom)
    echo "allocating"
    head -c 1000m /dev/zero | tail
    exit 0
    ;;
  env)
    env | grep '^TestFleet_' | sort
    exit 0
    ;;
  *)
    echo "unknown SPIKE_MODE ${SPIKE_MODE}" >&2
    exit 2
    ;;
esac
