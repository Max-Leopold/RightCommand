# RightCommand

A macOS menu bar utility that turns the underused Right Command key into an automatic app switcher. It detects all running applications and maps `Right ⌘ + <first letter of app name>` to switch to them. When multiple apps share the same starting letter, repeated presses cycle through them alphabetically.

## Build & Run

```
xcodebuild -scheme RightCommand -configuration Debug build
```

- **Target**: macOS 26.0
- **Swift**: 5.0 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- **Sandbox**: Disabled (`ENABLE_APP_SANDBOX = NO`) — required for CGEventTap / Accessibility API
- **Hardened Runtime**: Enabled
- **Xcode project format**: Uses `PBXFileSystemSynchronizedRootGroup` — any `.swift` file added to `RightCommand/` is automatically compiled

The app requires **Accessibility permission** at runtime. It prompts on first launch and polls every 2 seconds until granted.

## Architecture

Menu bar-only app (no dock icon, no main window). Uses `NSApplication.setActivationPolicy(.accessory)` at launch. Single scene: a window-style `MenuBarExtra` (`.menuBarExtraStyle(.window)`) that serves as both status display and shortcut reference.

### File Overview

| File | Role |
|---|---|
| `RightCommandApp.swift` | App entry point. Window-style `MenuBarExtra` scene, `AppDelegate` for lifecycle (start monitoring, accessibility polling). `MenuBarContent` view with header/status, flat app list with shortcut badges and pin toggles, and footer. `ShortcutBadge` view for keycap-styled shortcut hints. |
| `KeyMonitor.swift` | Core keyboard interception. CGEventTap setup, right-cmd detection, event suppression, cycling app activation. Also contains `availableKeys` table and `charToKeyCode` reverse lookup. |
| `RunningAppMonitor.swift` | `@Observable` class that watches running apps via `NSWorkspace` notifications. Builds letter→apps mappings (with app icons) and pushes keyCode→bundleIds to KeyMonitor. Manages pinned apps (persisted to UserDefaults). `AppInfo` stores `bundleId`, `name`, `icon: NSImage`, `isPinned`, `isRunning`. `PinnedApp` is a `Codable` struct for persistence. |

### Data Flow

```
AppDelegate
  ├── owns KeyMonitor
  ├── owns RunningAppMonitor (observes workspace launch/terminate notifications)
  └── applicationDidFinishLaunching:
        ├── setActivationPolicy(.accessory)
        ├── RunningAppMonitor.init → scans running apps → keyMonitor.updateAppMappings(...)
        ├── keyMonitor.start()  →  creates CGEventTap on main run loop
        └── startAccessibilityPolling()  →  Task loop until monitoring starts

RunningAppMonitor
  ├── NSWorkspace.didLaunchApplicationNotification  →  refresh()
  ├── NSWorkspace.didTerminateApplicationNotification  →  refresh()
  ├── pinnedApps: [String: PinnedApp]  (letter→pin, persisted to UserDefaults)
  └── refresh()  →  scans running apps + merges pinned-not-running apps
                 →  builds letter→[AppInfo] map (isPinned/isRunning flags)
                 →  keyMonitor.updateAppMappings(keyCode→[bundleId])
                    (pinned letters get single-element array, no cycling)

MenuBarContent (window-style popover)
  └── flattens monitor.appsByLetter into sorted app list with shortcut badges
      and pin toggle buttons (pin/unpin calls monitor.pin()/unpin())
```

## Right Command Key Detection — How It Works

This is the non-obvious core of the app. macOS `CGEventFlags.maskCommand` does not distinguish left from right Command. The distinction lives in **device-dependent flags** in the lower bits of the raw event flags value.

From `IOKit/hidsystem/IOLLEvent.h`:
```
NX_DEVICELCMDKEYMASK = 0x00000008   // Left Command
NX_DEVICERCMDKEYMASK = 0x00000010   // Right Command
```

### Detection State Machine (in `eventTapCallback`)

1. **`flagsChanged` event**: Read `event.flags.rawValue`. Set `gRightCmdDown = true` when bit `0x10` is set AND generic `.maskCommand` is set. Set `false` otherwise. Always pass the event through.
2. **`keyDown` event while `gRightCmdDown`**: Look up `keyCode` in `gAppsByKey`. If matched → cycle to the next app using `gLastActivatedByKey` tracking, activate via `Task { @MainActor in }` using `NSWorkspace.shared.openApplication`, return `nil` to suppress the event. If not matched → pass through.
3. **`tapDisabledByTimeout`**: Re-enable the tap. macOS disables taps that block for ~5 seconds.

### Cycling Logic

When `Right ⌘ + <key>` is pressed and multiple apps share that letter:
- Look up `gLastActivatedByKey[keyCode]` to find what we last switched to for this key
- If the last-activated app is in the list at index `i`, activate app at `(i+1) % count`
- If the last-activated app is not in the list (or first press), activate the first app (index 0)
- Update `gLastActivatedByKey[keyCode]` synchronously in the callback before dispatching the async activation Task
- Apps are sorted alphabetically by short name within each letter group

This approach is race-free: cycling state is updated synchronously in the callback, so rapid key presses always advance correctly regardless of how long the async activation takes.

### Why Left Cmd Is Unaffected

Left Command sets `NX_DEVICELCMDKEYMASK (0x08)` but NOT `0x10`. So `gRightCmdDown` stays `false` when only left cmd is held, and all keyDown events pass through unmodified.

## Concurrency Model

The project uses Swift 6.2's default MainActor isolation. All types are implicitly `@MainActor`.

The CGEventTap callback is a C function pointer — inherently nonisolated. It runs on the main run loop (main thread), but Swift's type system doesn't know that. The bridge between the two worlds:

- **Global state** (`gRightCmdDown`, `gAppsByKey`, `gLastActivatedByKey`, `gEventTap`): Declared `nonisolated(unsafe)`. Safe because both the C callback and MainActor code run on the main thread.
- **App activation from the callback**: Uses `Task { @MainActor in }` with `NSWorkspace.shared.openApplication(at:configuration:)` for robust activation that reliably brings windows to the foreground. Event suppression (`return nil`) happens synchronously before the Task executes.

**Important**: Do NOT call `MainActor.assumeIsolated` or access `NSWorkspace.shared` synchronously from the CGEventTap callback. While technically on the main thread, this disrupts the activation context and prevents target app windows from being raised. All Cocoa API calls must go through the async `Task { @MainActor in }` path.

## Running App Detection

`RunningAppMonitor` scans `NSWorkspace.shared.runningApplications` on init and whenever an app launches or terminates. It filters to:
- `activationPolicy == .regular` (visible GUI apps only, not background agents)
- Non-nil, non-empty app name
- Name starts with A-Z or 0-9
- Deduplicated by bundle identifier
- Excludes its own bundle identifier

### App Name Resolution

App names are resolved using `CFBundleName` from the app's `Info.plist`, falling back to `NSRunningApplication.localizedName`. This is critical because `localizedName` often includes the company name (e.g. "Google Chrome") while `CFBundleName` gives the short name users expect (e.g. "Chrome"). Without this, Chrome would map to `G` instead of `C`.

The `availableKeys` table in `KeyMonitor.swift` maps A–Z and 0–9 to their US-layout hardware keyCodes. These are physical key positions, not layout-dependent characters.

## App Pinning

Users can **pin** an app to its shortcut letter. When pinned:
- `Right ⌘ + letter` ALWAYS activates that specific app, even if it's not running (launches it)
- No cycling — the pinned app is the sole target for that letter
- Other running apps sharing the letter lose their shortcut badge in the UI
- Pins persist across app restarts via `UserDefaults` (key: `"pinnedApps"`, JSON-encoded `[String: PinnedApp]`)
- Pinned-but-not-running apps appear in the menu bar dropdown at 60% opacity with their bundle icon
- On load, stale pins (uninstalled apps) are silently removed

### Pin Data Flow
- `RunningAppMonitor.pin(letter:bundleId:name:)` → saves to UserDefaults → `refresh()`
- `refresh()` step 4: pinned letters get `keyCodeMap[keyCode] = [pinnedBundleId]` (single element = no cycling)
- The CGEventTap callback already uses `NSWorkspace.shared.openApplication(at:configuration:)` which launches non-running apps

## Key Behavioral Details

- **Unmatched keys with right cmd held**: Pass through as normal `Cmd+<key>` to the foreground app.
- **Pinned apps**: Always activated for their letter, even when not running (launched via `openApplication`).
- **Non-pinned apps on pinned letters**: Still appear in the UI list but without a shortcut badge. Their shortcut is inactive while the pin is in effect.
- **Auto-updating**: Mappings refresh automatically when apps launch or quit. No manual configuration needed.
- **Both left+right cmd held**: Right cmd shortcuts still trigger (right cmd bit is set).
- **Modifier combos** (right cmd + shift + key): Still triggers the shortcut (matches on keyCode only, ignores other modifiers).
- **Secure Input limitation**: Apps that enable Secure Input (Terminal, password fields in browsers) cause macOS to stop delivering keyboard events to CGEventTaps. Shortcuts will not work while such fields are focused. This is an OS-level security feature and cannot be bypassed.
