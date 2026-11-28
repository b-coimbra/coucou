#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-devflow.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=NotchBuddy/Sources/App/DevFlow
swiftc -swift-version 6 -strict-concurrency=complete \
    "$SOURCES/DevFlowPills.swift" \
    "$SOURCES/JiraIssue.swift" \
    "$SOURCES/GitGlance.swift" \
    "$SOURCES/PullRequests.swift" \
    "$SOURCES/DevProcess.swift" \
    "$SOURCES/DevFlowReaders.swift" \
    tests/DevFlowTests.swift -o "$TEST_DIR/devflow-tests"
"$TEST_DIR/devflow-tests"
