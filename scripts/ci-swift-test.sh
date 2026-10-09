#!/usr/bin/env bash
# Run `swift test` under a watchdog that samples a hang instead of waiting it out.
#
# A test that never returns used to take the whole job with it: the runner's
# job cap force-cancels the run, and GitHub keeps no log for a cancelled job,
# so the one fact worth having — which test never returned, and what its
# threads were doing — is gone. That is how the Intel leg of the macOS
# workflow burned 30 minutes on the ghostty 1.0.25 merge and left nothing to
# read (run 34820337118).
#
# So bound the run here, below the job cap: when the deadline passes, sample
# the test processes, print the stacks into the job log, and kill them. The
# step then fails normally, which is what keeps the log.
set -uo pipefail

minutes="${SWIFT_TEST_TIMEOUT_MINUTES:-15}"

swift test "$@" &
tests=$!

(
    sleep $((minutes * 60))
    echo "::error::swift test has not finished after ${minutes}m — sampling"
    ps -o pid,etime,command -p "$tests" || true

    # The hang is in the xctest child, not in the `swift test` driver waiting
    # on it. Before the tests start running there is no such child, so fall
    # back to the driver's own descendants — a build that wedged is worth the
    # same stack.
    pids="$(pgrep -f 'xctest|swiftpm-testing-helper|fyoloPackageTests' || true)"
    [ -n "$pids" ] || pids="$tests $(pgrep -P "$tests" || true)"
    for pid in $pids; do
        echo "--- sample $pid: $(ps -p "$pid" -o command= | cut -c1-160)"
        sample "$pid" 5 -file /dev/stdout 2>&1 || true
    done

    pkill -9 -f 'xctest|swiftpm-testing-helper|fyoloPackageTests' || true
    kill -9 "$tests" 2>/dev/null || true
) &
watchdog=$!

wait "$tests"
status=$?
kill "$watchdog" 2>/dev/null || true
exit "$status"
