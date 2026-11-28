#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agents.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=NotchBuddy/Sources/App/Agents
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/ClaudePlanGauge.swift \
    "$SOURCES/AgentPills.swift" \
    "$SOURCES/UsageReset.swift" \
    "$SOURCES/ClaudeJobs.swift" \
    "$SOURCES/ClaudeJobReader.swift" \
    "$SOURCES/CursorPingDetector.swift" \
    tests/AgentsTests.swift -o "$TEST_DIR/agents-tests"
"$TEST_DIR/agents-tests"
