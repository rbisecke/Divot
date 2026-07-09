#!/bin/bash
# Build SwingCore + run the headless check harness (T1). Output to /tmp/sc.log.
# Relocatable: resolves the package dir from this script's own location.
PKG="$(cd "$(dirname "$0")" && pwd)"
: > /tmp/sc.log
swift build --package-path "$PKG" >> /tmp/sc.log 2>&1
echo "build_rc=$?" >> /tmp/sc.log
swift run --package-path "$PKG" swingcore-check >> /tmp/sc.log 2>&1
echo "check_rc=$?" >> /tmp/sc.log
