#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-day.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=NotchBuddy/Sources/App/Day
# GrokBotReader: the one-line text cleaner. ClaudePlanGauge and UsageReset: DailyResetTime.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/GrokBotReader.swift \
    NotchBuddy/Sources/App/ClaudePlanGauge.swift \
    NotchBuddy/Sources/App/Agents/UsageReset.swift \
    "$SOURCES/DayPills.swift" \
    "$SOURCES/Meetings.swift" \
    "$SOURCES/FocusFilter.swift" \
    "$SOURCES/TimesheetSchedule.swift" \
    "$SOURCES/DaySettings.swift" \
    tests/DayTests.swift -o "$TEST_DIR/day-tests"
"$TEST_DIR/day-tests"
