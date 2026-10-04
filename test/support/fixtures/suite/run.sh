#!/bin/sh
# Behaves according to FIXTURE_MODE; the modes are listed in the spec's "Testing" section.
set -u

artifacts="${TestFleet_ARTIFACTS_DIR:-/TestFleet/artifacts}"

write_artifacts() {
  mkdir -p "$artifacts/reports"
  echo "run $TestFleet_RUN_ID" > "$artifacts/summary.txt"
  echo "<html><body>report</body></html>" > "$artifacts/reports/index.html"
}

# junit FILE TESTCASES: writes a JUnit report with the given <testcase> elements.
junit() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="e2e">%s</testsuite></testsuites>\n' "$2" > "$1"
}

tick_forever() {
  i=0
  while true; do
    i=$((i + 1))
    echo "tick $i"
    sleep 1
  done
}

case "${FIXTURE_MODE:-pass}" in
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
  secret)
    # Suites echo configuration; TestFleet must mask it.
    echo "token=${FIXTURE_SECRET} in the middle"
    echo "${FIXTURE_SECRET}"
    echo "twice: ${FIXTURE_SECRET} ${FIXTURE_SECRET}" >&2
    echo "not secret: ${FIXTURE_PLAIN:-}"
    exit 0
    ;;
  junit_pass)
    mkdir -p "$artifacts"
    junit "$artifacts/junit.xml" '<testcase classname="Smoke" name="loads" time="0.5"/><testcase classname="Smoke" name="later"><skipped/></testcase>'
    exit 0
    ;;
  junit_fail)
    mkdir -p "$artifacts/screenshots"
    echo "not really a png" > "$artifacts/screenshots/checkout.png"
    junit "$artifacts/junit.xml" '<testcase classname="Cart" name="adds" time="1"/><testcase classname="Cart" name="pays" time="2"><failure message="expected 200, got 500">at pay (cart.spec.ts:12)</failure></testcase><testcase classname="Cart" name="crashes"><error message="TypeError"/></testcase>'
    exit 1
    ;;
  junit_swallow)
    mkdir -p "$artifacts"
    junit "$artifacts/junit.xml" '<testcase classname="Cart" name="pays"><failure message="expected 200"/></testcase>'
    exit 0
    ;;
  junit_crash)
    mkdir -p "$artifacts"
    junit "$artifacts/junit.xml" '<testcase classname="Cart" name="adds"/>'
    echo "reporter crashed" >&2
    exit 1
    ;;
  junit_shards)
    mkdir -p "$artifacts/junit"
    junit "$artifacts/junit/shard-1.xml" '<testcase classname="A" name="one"/>'
    junit "$artifacts/junit/shard-2.xml" '<testcase classname="B" name="two"><failure message="no"/></testcase>'
    echo "not xml" > "$artifacts/junit/broken.xml"
    exit 1
    ;;
  big_artifacts)
    mkdir -p "$artifacts"
    junit "$artifacts/junit.xml" '<testcase classname="Big" name="records a video"/>'
    head -c "$((${FIXTURE_ARTIFACT_MB:-5} * 1024 * 1024))" /dev/zero > "$artifacts/video.webm"
    exit 0
    ;;
  unsafe_artifacts)
    mkdir -p "$artifacts"
    echo "kept" > "$artifacts/report.txt"
    ln -s /etc/passwd "$artifacts/passwd"
    exit 0
    ;;
  report)
    # A failing suite with a real screenshot and an HTML report, for trying the
    # artifacts panel by hand. The report's script shows whether it runs sandboxed.
    mkdir -p "$artifacts/screenshots" "$artifacts/report"
    junit "$artifacts/junit.xml" '<testcase classname="Checkout" name="shows the cart" time="1.2"/><testcase classname="Checkout" name="pays by card" time="3.4"><failure message="expected the receipt, saw an error page">at pay (checkout.spec.ts:42)
at runTest (runner.js:7)</failure></testcase>'
    echo "iVBORw0KGgoAAAANSUhEUgAAAUAAAAC0CAIAAABqhmJGAAACfklEQVR4nO3TwQkCQQAEwY3E54ExmH8Wvi4KEREfZrCcLs0VVADzmB6X6w2IGssXANMEDGEChjABQ5iAIUzAECZgCBMwhAkYwgQMYQKGMAFDmIAhTMAQJmAIEzCECRjCBAxhAoYwAUOYgCFMwBAmYAgbj+cLiBIwhAkYwgQMYQKGMAFDmIAhTMAQJmAIEzCECRjCBAxhAoYwAUOYgCFMwBAmYAgTMIQJGMIEDGEChjABQ5iAIUzAECZgCBMwhAkYwgQMYQKGMAFDmIAhTMAQJmAIEzCECRjCBAxhAoYwAUOYgCFMwBAmYAgTMIQJGMIEDGEChjABQ1gy4Pu2wS8s/7aAYd7yb58o4Pe+w1EELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBCxgwgQsYMIELGDCBPzvgOFwy78tYJi3/NunCBj4EjCECRjCBAxhAoYwAUOYgCFMwBAmYAgTMIQJGMIEDGEChjABQ5iAIUzAECZgCBMwhAkYwgQMYQKGMAFDmIAhTMAQJmAIEzCECRjCBAxhAoYwAUOYgCFMwBAmYAgTMIQJGMIEDGEChjABQ5iAIUzAECZgCBMwhAkYwgQMYQKGMAFDmIAhTMAQJmAIEzCECRjCBAxhAoYwAUOYgCFMwBAmYAgTMIQJGMI+NGmQ8M4nDEYAAAAASUVORK5CYII=" | base64 -d > "$artifacts/screenshots/checkout.png"
    echo "body { font-family: sans-serif; margin: 2rem; } .ok { color: #15803d; } .bad { color: #b91c1c; }" > "$artifacts/report/style.css"
    cat > "$artifacts/report/index.html" <<'HTML'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>E2E report</title><link rel="stylesheet" href="style.css"></head>
<body>
<h1>E2E report</h1>
<p>1 passed, 1 failed. <a href="../screenshots/checkout.png">Screenshot</a></p>
<p id="sandbox">Checking the sandbox…</p>
<script>
  var el = document.getElementById("sandbox");
  var cookies;
  try { document.cookie; cookies = "readable"; } catch (e) { cookies = "blocked"; }
  var sandboxed = window.origin === "null" && cookies === "blocked";
  el.className = sandboxed ? "ok" : "bad";
  el.textContent = (sandboxed ? "Sandboxed" : "NOT sandboxed") +
    ": origin " + window.origin + ", cookies " + cookies + ". Scripts run.";
</script>
</body>
</html>
HTML
    exit 1
    ;;
  tick)
    # Ticks for FIXTURE_TICKS seconds, then passes.
    i=0
    while [ "$i" -lt "${FIXTURE_TICKS:-5}" ]; do
      i=$((i + 1))
      echo "tick $i"
      sleep 1
    done
    exit 0
    ;;
  *)
    echo "unknown FIXTURE_MODE ${FIXTURE_MODE}" >&2
    exit 2
    ;;
esac
