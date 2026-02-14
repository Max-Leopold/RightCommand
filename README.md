# RightCommand

A macOS menu bar utility that turns the Right Command key into an instant app switcher.

It detects all running apps and maps **Right ⌘ + first letter** to switch to them. When multiple apps share the same letter, repeated presses cycle through them alphabetically.

## How It Works

- Mappings update automatically as apps launch and quit — no configuration needed.
- Pinned apps are launched if not already running; unpinned mappings only switch to running apps.
- Left Command is completely unaffected.
- Unmatched keys pass through as normal `Cmd+` shortcuts.
