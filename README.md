# Hammerspoon window management

A [Hammerspoon](https://www.hammerspoon.org) config for moving windows from
the keyboard and putting every app back on its desktop after docking or
undocking. It leaves out `hs.ipc`, third-party Spoons and crash-report
uploads, so all it does is move windows.

## Install

```sh
brew install --cask hammerspoon
git clone <this repo's URL> ~/.hammerspoon
open -a Hammerspoon
```

If you already have a `~/.hammerspoon`, move it aside first. On first launch,
grant Hammerspoon **Accessibility** in System Settings > Privacy & Security,
or no binding fires. It reloads itself whenever a `.lua` file changes, and the
menu bar icon has **Reload Config** too.

To update, `git -C ~/.hammerspoon pull`.

## Bindings

| Keys | Does |
| --- | --- |
| `ctrl+cmd+arrows` | Move through a 3x2 grid of sections; left/right at an edge cycle 1/2, 1/4, 3/4 width |
| `ctrl+cmd+left+right` | Center at half width, full height |
| `ctrl+alt+arrows` | Resize by 5% of the screen |
| `ctrl+shift+alt+arrows` | Nudge by 5% of the screen |
| `ctrl+alt+cmd+arrows` | Throw to the display in that direction, filling it |
| `ctrl+alt+1/2/3` | Throw to display 1/2/3, filling it |
| `ctrl+5` | Center at half size |
| `ctrl+alt+space` or `ctrl+alt+e` / `ctrl+alt+s` | Grow / shrink around the center |
| `cmd+escape` | Window hints: press a letter to focus that window |
| `ctrl+alt+cmd+s` | Save the desktop map (`+shift` forgets apps that are not running) |
| `ctrl+alt+cmd+r` | Restore the desktop map |

Any hotkey macOS already owns is listed in an alert when the config loads.

## Desktop maps

`ctrl+alt+cmd+s` records which desktop each app's windows are on, across all
desktops and displays, along with their sizes as fractions of the screen.
`ctrl+alt+cmd+r` moves every window of those apps back. Nothing runs on its
own; press the hotkey after docking or undocking.

There is one map per set of screens (laptop alone, monitor with the lid
closed, laptop + monitor). Screens without a map of their own use the newest
one saved with as many screens, matching displays by name, then by role
(built-in, or the largest external), so a map saved at one desk restores onto
a different monitor at another until you save one there.

Hammerspoon cannot see windows on a desktop that is not showing, and macOS
ignores other apps asking to move a window to another desktop, so save and
restore step each display through its desktops and move windows the way a
person would: across displays by showing both desktops, on one display by
holding the title bar and pressing **Move left/right a space**. Turn those
shortcuts on (any keys) under System Settings > Keyboard > Keyboard Shortcuts
> Mission Control. Expect several seconds of desktops switching and the
pointer moving; keep hands off the mouse until the "Restored desktops" alert.

Maps live in `~/.hammerspoon/desktops.json`, one per machine and gitignored,
and can be edited by hand. `~/.hammerspoon/restore.log` has what the last save
or restore saw and did.

## Per-machine overrides

Copy `init.local.lua.example` to `init.local.lua` (gitignored) for bindings
that only make sense on one machine, such as throwing to a display by index
when your monitors sit side by side. It loads after every shared binding, and
in Hammerspoon the newest bind on a key combination wins, so it can override
anything here.
