# Edge Light

A thin glowing line around the screen that lights up when something happens, ported
from Minhoca. GitHub build only: every file is wrapped in `#if !APPSTORE`.

## Where the settings are

Coucou window (**Settings…**, ⌘,) → sidebar, notch section → **Edge Light**. The
settings search of that window finds its three boxes.

| Box | Setting | Default |
|-----|---------|---------|
| Edge Light | Enable Edge Light (master switch) | off |
| | Do not disturb | off |
| | Continuous mode | off |
| Appearance | Line thickness, 0.5 to 6 pt | 1.5 pt |
| | Corner radius: Auto (≈4 mm), 8, 10, 12, 14, 16 pt | Auto |
| | Glow | on |
| | Follow the notch | on |
| Sources | Per source: on/off, color, **Test** | all on |

The sources box lists Grok Bot, Claude, Cursor, Slack and Mail, then Codex, Gemini,
Antigravity, Copilot, Muse, OpenCode, Amp and Hermes under **Other agents**. The
Claude row covers Claude Code and Claude Desktop. Slack has four colors, one per
step of its sweep. **Reset colors** restores the defaults.

Changes apply right away, without a restart.

- **Test** plays that source's comet on the screen being worked on, even if the
  source is off or Do not disturb is on. It needs the master switch.
- **Do not disturb** is Coucou's own switch (it does not read macOS Focus). It
  stops the comets, the continuous line and the badge polling.

## What triggers it

| Source | Trigger |
|--------|---------|
| Agents (Claude Code, Cursor, Codex…) | A turn ends (`Stop` hook) while the terminal is not in front (`HookServer.swift`) |
| Grok Bot | A new assistant message, when the Grok Bot pill is active (`GrokBotPoller.swift`) |
| Slack, Mail | The Dock badge count goes up |

A new trigger replaces the comet already running.

## Files (`NotchBuddy/Sources/App/EdgeLight/`)

| File | Role |
|------|------|
| `EdgeLightGeometry.swift` | The closed path along the screen edges: continuous-curvature corners, notch contour, sampling by arc length |
| `EdgeLightAnimator.swift` | Comet and continuous line, as a list of draw items for a given time |
| `EdgeLightView.swift` | The scene, and the SwiftUI `Canvas` driven by a `TimelineView` |
| `EdgeLightOverlay.swift` | The window, and when it is on screen |
| `EdgeLightController.swift` | Triggers, settings changes, screen changes, path building, sources |
| `EdgeLightBadgeMonitor.swift` | Slack and Mail badge counts |
| `EdgeLightSettings.swift` | `UserDefaults`-backed settings (`edgeLight.*`) |
| `EdgeLightSettingsView.swift` | The settings page |

Outside this folder: `HookServer.swift`, `GrokBotPoller.swift` and
`AppDelegate.swift` (triggers and launch), `SettingsView.swift`, `FlowHub.swift`,
`FlowHubMochis.swift` and `SettingsSearch.swift` (settings page), and
`Localizable.xcstrings` (the `edge-light.*` strings, 16 languages).

## Overlay window

A borderless, non-activating `NSPanel` that can't become key or main: transparent,
click-through, at main menu level + 5 (above regular windows, the menu bar and
Coucou's island, so the island can't hide the line), on all spaces and over
fullscreen apps. It stays when Coucou is not the active app.

It covers one screen, `NSScreen.main` (the one with keyboard focus), read at each
trigger, settings change and screen change.

## Animation

**Comet**: two heads leave the top center in opposite directions and meet at the
bottom center, with a tail of 25 % of the perimeter. Two laps of 2 s, then a 0.8 s
fade (4.8 s in all). Slack's colors sweep from top to bottom.

**Continuous mode**: six fixed colors turning around the screen (6 s per turn) at
80 % opacity, with one lighter comet on top (5 s per turn). A source's comet plays
over it.

**Corners**: superellipse starting 1.528 × the radius from the corner. The radius
is the screen's; the line's own is smaller by its distance to the edge (half the
line width + 1 pt). "Auto" is 4 mm converted with the display's physical size
(6 to 24 pt), 12.5 pt when it is unknown. Same radius top and bottom.

**Notch**: read from `safeAreaInsets` and the auxiliary top areas. The line runs
half its width + 1 pt outside the cutout, with 4 pt concave flares at the top edge
and bottom corners of 8 pt + that clearance.

## Badge monitoring

Every 3 s, while Slack or Mail is on:

- `/usr/bin/lsappinfo find bundleid=<id>`, then
  `/usr/bin/lsappinfo info -only StatusLabel <asn>`
- `"3"` → 3, `"•"` → 1, `"99+"` → 99, `""` → 0
- Triggers only when a count goes up (never on the first read)
- No message content is read, no network, no permission asked

## Performance

- Nothing animating: the window is off screen and the `TimelineView` does not
  exist, so no frame is scheduled. The badge poll is the only periodic work, and it
  stops with Slack and Mail off, Do not disturb on, or the feature off.
- Comet: 60 fps for 4.8 s.
- Continuous mode: 30 fps for as long as it is on.

CPU use has not been measured.

## Verification

Done with the command line tools (Swift 6.3.3, `-strict-concurrency=complete`):

- The Edge Light files, with `ColorHex.swift` and a small scratch harness, compile
  without errors or warnings.
- The `-D APPSTORE` variant of the app sources type-checks.
- The GitHub variant was type-checked without FluidAudio: the only errors came from
  the two files left out and from the missing `FoundationModels` macro plugin.

Still to do:

- [ ] Full `xcodebuild` (CI)
- [ ] On a Mac: drawing, notch alignment, corner radius, click-through, all spaces,
      fullscreen, no focus stealing
- [ ] Slack and Mail badge reading
- [ ] CPU use, idle and animating
- [ ] Translations of the new strings reviewed by speakers

`NotchBuddy/Tests/EdgeLightGeometryTests.swift` is compiled with the app's geometry
file (the command is at its top). `EdgeLightBadgeTests.swift` is a standalone script
that carries its own copy of the logic: it does not exercise the app's types.

## Syncing upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main
git push origin main

git checkout cursor/grok-bot-integration-3f70
git rebase main
# Resolve any conflicts
git push --force-with-lease
```
