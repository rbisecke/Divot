#!/bin/bash
# Build SwingCore + run the headless check harness (T1). Output to /tmp/sc.log.
# Relocatable: resolves the package dir from this script's own location.
PKG="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$PKG/.." && pwd)"

# Fixture-gated sections (Replay, MLM2ProCSV) run against the repo's own committed synthetic
# fixtures by default, so `make validate` exercises them on a clean clone/in CI instead of
# silently skipping (code-review-findings.md #1). SWINGCORE_TEST_CLIP/_DTL_CLIP are deliberately
# left unset here: a real swing clip can't be committed (privacy hard rule), so those sections
# keep skipping unless a developer points them at a local clip.
export SWINGCORE_TEST_POSE_JSON="${SWINGCORE_TEST_POSE_JSON:-$REPO/ios/DivotTests/Fixtures/sample_swing.pose.json}"
export SWINGCORE_TEST_CSV="${SWINGCORE_TEST_CSV:-$REPO/ios/DivotTests/Fixtures/sample_shots.csv}"

# Minimum checks expected to run with only the repo-committed fixtures available (no real clip).
# A count below this means a section that should be running silently mass-skipped again.
MIN_CHECKS=100

: > /tmp/sc.log
swift build --package-path "$PKG" >> /tmp/sc.log 2>&1
build_rc=$?
echo "build_rc=$build_rc" >> /tmp/sc.log
if [ "$build_rc" -ne 0 ]; then
    echo "build failed, not running checks" >> /tmp/sc.log
    exit 1
fi
swift run --package-path "$PKG" swingcore-check >> /tmp/sc.log 2>&1
echo "check_rc=$?" >> /tmp/sc.log

count="$(grep -oE 'ALL PASS, [0-9]+ checks' /tmp/sc.log | grep -oE '[0-9]+')"
if [ -n "$count" ] && [ "$count" -lt "$MIN_CHECKS" ]; then
    echo "check count $count is below the expected floor of $MIN_CHECKS -- a section likely mass-skipped" >> /tmp/sc.log
    exit 1
fi
