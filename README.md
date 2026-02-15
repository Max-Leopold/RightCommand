# RightCommand

A macOS menu bar utility that turns the Right Command key into an instant app switcher.

It detects all running apps and maps **Right ⌘ + first letter** to switch to them. When multiple apps share the same letter, repeated presses cycle through them alphabetically.

## Install

1. Download `RightCommand.zip` from the [latest release](../../releases/latest)
2. Unzip and move `RightCommand.app` to `/Applications`
3. On first launch, macOS will block it — right-click the app → **Open** → **Open** to bypass Gatekeeper
4. Grant **Accessibility** access when prompted (System Settings → Privacy & Security → Accessibility)

## How It Works

- Mappings update automatically as apps launch and quit — no configuration needed.
- Pinned apps are launched if not already running; unpinned mappings only switch to running apps.
- Left Command is completely unaffected.
- Unmatched keys pass through as normal `Cmd+` shortcuts.
