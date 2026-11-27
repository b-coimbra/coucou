# Grok Bot Integration for Coucou - Implementation Summary

## ✅ Completed

A complete Grok Bot integration has been added to your Coucou fork (b-coimbra/coucou) in the branch `cursor/grok-bot-integration-3f70`.

**Pull Request**: https://github.com/b-coimbra/coucou/pull/1

## What Was Built

### Core Functionality

The integration adds a "Grok Bot" pill that:
1. **Monitors** Grok Bot's local storage (`~/Library/Application Support/Grok Bot/sand-client-persistence/`)
2. **Detects** new assistant messages from your Grok Bot conversations
3. **Shows** the latest message preview in Mochi's notch (bot name + first 60 chars)
4. **Reacts** with Mochi's finish animation and sound
5. **Opens** the Grok Bot app when clicked (brings it forward if already running)

### Files Created

1. **NotchBuddy/Sources/App/GrokBotReader.swift** (304 lines)
   - Swift port of your Python reader (grokbot.py)
   - Secure blob file reading (computed filenames only, no directory listing)
   - Parses: account slot → roster → transcript replicas
   - Markdown cleaning, timestamp conversion
   - New message detection with per-bot timestamp tracking

2. **NotchBuddy/Sources/App/GrokBotPoller.swift** (104 lines)
   - Background polling every 2 seconds (as specified)
   - Off main thread, mtime-based change detection
   - Follows StripePoller pattern
   - Triggers Mochi reactions on new messages

3. **NotchBuddy/Tests/GrokBotReaderTests.swift** (207 lines)
   - Unit tests for blob name conversion
   - Markdown cleaning tests
   - Timestamp conversion tests
   - Deterministic behavior verification

### Files Modified (Minimal Changes)

1. **NotchBuddy/Sources/CoucouKit/PillCatalog.swift**
   - Added Grok Bot pill entry:
     - ID: `agent_grokbot`
     - Name: "Grok Bot"
     - Color: `#10B981` (brand green)
     - Category: `.agent`
     - `githubOnly: true` (requires filesystem access)

2. **NotchBuddy/Sources/App/AppState.swift**
   - Added 4 @Published properties for Grok Bot state

3. **NotchBuddy/Sources/App/IslandViewContent.swift**
   - Added pill click handler (opens Grok Bot app)
   - Added configuration check (app + storage directory)

4. **NotchBuddy/Sources/App/AppDelegate.swift**
   - Added poller startup (GitHub build only)

5. **README.md**
   - Added "Grok Bot" to agent list with note about macOS GitHub build

## Security Rules (From Python Reference)

✅ All security rules from grokbot.py were preserved:

- **Opens ONLY computed blob files** for known keys (never lists/scans directory)
- **Zero network calls**
- **Never persists message text** to disk (only IDs and timestamps)
- **Display-only text** (never opens links or executes content from messages)
- **Polls ~every 2s** using mtime checks off the main thread
- **GitHub-build-only** flag (requires file access outside App Store sandbox)

## How to Build & Test

### Prerequisites

- macOS 15+
- Xcode 16+
- XcodeGen installed: `brew install xcodegen`
- Grok Bot app installed (for testing)

### Build Commands

```bash
# Navigate to NotchBuddy directory
cd NotchBuddy

# Generate Xcode project
xcodegen

# Build (option 1 - basic build)
xcodebuild -scheme NotchBuddy -configuration Debug build

# Build (option 2 - signed, recommended for day-to-day)
cd ..
./scripts/dev-install.sh
```

### Run Unit Tests

```bash
# From repo root
swift NotchBuddy/Tests/GrokBotReaderTests.swift
```

### Testing the Integration

1. **Enable the pill**: 
   - Launch Coucou
   - Open Settings → Active pills
   - Enable "Grok Bot"

2. **Verify detection**:
   - Open Grok Bot app
   - Send a message to any assistant
   - Wait for assistant reply
   - Coucou should show notification in notch within 2 seconds

3. **Test pill click**:
   - Click the Grok Bot pill in Coucou
   - Grok Bot app should come forward (or launch if closed)

## Syncing Upstream Later

To keep receiving updates from Louis-CFM/coucou:

```bash
# One-time setup: add upstream remote
git remote add upstream https://github.com/Louis-CFM/coucou.git

# Regular sync workflow:
git fetch upstream
git checkout main
git merge upstream/main
git push origin main

# Rebase your feature branch:
git checkout cursor/grok-bot-integration-3f70
git rebase main
# Resolve any conflicts
git push --force-with-lease
```

## Technical Details

### Blob Name Conversion

The key-to-filename mapping uses lowercase unpadded base32:
- Key: `"sand.client.slice.client-meta.account-slot"`
- Becomes: `"<base32-encoded>.blob"`

### Message Detection Logic

1. Read account slot key to get user's slot ID
2. Read roster to get list of all bots
3. For each bot, read its transcript replica
4. Parse messages, track latest timestamp per bot
5. Filter for messages newer than last seen
6. Show preview: bot name + first 60 chars of text

### Polling Strategy

- **Interval**: 2 seconds
- **Thread**: Background QoS
- **Change detection**: File mtime
- **Cache**: Blob contents cached by (mtime, size)
- **Pauses**: Respects DemoEngine.isPollerPaused

## Unverified / Needs Testing

Since this environment doesn't have macOS build tools:

- [ ] **Build succeeds** - Please verify with xcodegen + xcodebuild
- [ ] **Tests pass** - Run unit tests with Swift compiler
- [ ] **Grok Bot bundle ID** - Assumed `com.xAI.Grok-Bot`, may need adjustment
- [ ] **Blob format matches** - Implementation based on Python reference
- [ ] **Runtime behavior** - Needs Grok Bot app installed to test
- [ ] **Mtime polling works** - Should detect changes within 2 seconds
- [ ] **Click handler works** - Pill should open Grok Bot app

## Known Assumptions

1. **Grok Bot app bundle ID**: `com.xAI.Grok-Bot`
   - If incorrect, update in `IslandViewContent.swift` line ~343
   
2. **Storage path**: `~/Library/Application Support/Grok Bot/sand-client-persistence/`
   - Matches Python reference; should be stable

3. **Blob format**: JSON with `{"value": ...}` structure
   - Based on Python reference behavior

4. **Message kinds**: Only processes `"send-message"` kind
   - Other kinds are ignored (may need expansion)

## Color Choice

Chose `#10B981` (emerald green) for the Grok Bot pill:
- Differentiates from existing pills (Claude=#D97757, Gemini=#8AB4F8, etc.)
- Tech/AI feel without clashing with other integrations
- Visible against Coucou's dark interface

## Code Quality

- **Swift 6** strict concurrency mode
- **Zero dependencies** (pure Swift/Foundation)
- **@MainActor** for AppState updates
- **@unchecked Sendable** for safe background threading
- **Follows repo conventions**: PillCatalog, poller pattern, AppState properties

## Next Steps

1. **Build verification**: Run xcodegen + xcodebuild
2. **Fix any compilation errors** (unlikely, but possible)
3. **Test with Grok Bot app**: Verify message detection
4. **Adjust bundle ID if needed**: Check actual Grok Bot app
5. **Merge PR** if everything works
6. **Sync upstream regularly**: Keep receiving Louis's updates

## Support

If you encounter issues:

1. **Build errors**: Check Xcode version (needs 16+) and macOS version (needs 15+)
2. **Bundle ID wrong**: Find correct ID with `osascript -e 'id of app "Grok Bot"'`
3. **No messages detected**: Check if `~/Library/Application Support/Grok Bot/` exists
4. **Merge conflicts later**: The changes are minimal and self-contained, should be easy to resolve

## Commit Details

**Branch**: `cursor/grok-bot-integration-3f70`  
**Commit SHA**: c804b29  
**Files changed**: 8 files, 640 insertions(+), 1 deletion(-)

---

Built following all requirements:
✅ Minimal invasiveness (new files, minimal shared changes)  
✅ Security rules from Python preserved  
✅ GitHub-build-only (githubOnly flag)  
✅ 2-second polling off main thread  
✅ Zero network, no text persistence  
✅ Unit tests written  
✅ README updated  
✅ Ready for PR within fork (not to upstream)
