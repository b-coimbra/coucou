#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-glance.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
APP=NotchBuddy/Sources/App
# The glance reads the other features' own types: pull requests, Jira, meetings, usage.
swiftc -swift-version 6 -strict-concurrency=complete \
    "$APP/GrokBotReader.swift" \
    "$APP/ClaudePlanGauge.swift" \
    "$APP/DevFlow/DevFlowPills.swift" \
    "$APP/DevFlow/JiraIssue.swift" \
    "$APP/DevFlow/PullRequests.swift" \
    "$APP/Agents/AgentPills.swift" \
    "$APP/Agents/UsageReset.swift" \
    "$APP/Day/DayPills.swift" \
    "$APP/Day/Meetings.swift" \
    "$APP/Badges/DockBadge.swift" \
    "$APP/Glance/GlanceItems.swift" \
    tests/GlanceTests.swift -o "$TEST_DIR/glance-tests"
"$TEST_DIR/glance-tests"
