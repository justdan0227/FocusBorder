# FocusBorder

Draws a border around the active window on macOS.

FocusBorder is a fork of [Alan](https://github.com/tylerhall/Alan) by
[Tyler Hall](https://github.com/tylerhall), who wrote the original and everything good about the
idea. His note on the upstream repo still applies: *"this app is more software satire than useful
utility :)"* — this fork just took the satire a little too seriously.

The app, the Xcode project and the bundle id are all named FocusBorder here, to keep this fork
clearly distinct from Tyler's app. His authorship is preserved in the per-file headers and in
the license.

Upstream is MIT licensed and remains so here; see [LICENSE](LICENSE).

## What this fork adds

**The border keeps up with a dragged window.** Upstream's border visibly trailed behind a window
you were dragging. The cause turned out to be a system limit rather than a bug in the app: macOS
coalesces Accessibility move notifications to roughly 10Hz — measured at exactly 100ms intervals
from Finder and 117ms from Warp — so no amount of tuning the AX path can fix it. While the left
mouse button is down this fork reads window position straight from the WindowServer at 120Hz
instead, matching the tracked window to a `CGWindowID` by pid and geometry. No private API, and
no Screen Recording permission (only geometry keys are read, never window names).

**Highlight the window under the pointer.** An optional mode that follows the mouse instead of
keyboard focus, for finding a window buried under others. A 100ms dwell keeps the border from
flashing through every window the pointer merely crosses.

**Auto-hide.** The border can hide itself after a configurable number of seconds. In focus mode
it hides once the focused window has held focus that long, and stays hidden until focus moves to
a different window. In pointer mode there is no discrete target to count against, so it hides
once the pointer stops moving and returns the moment it moves again.

**Preferences for all of it**, plus a menu bar icon and an optional hide-from-Dock mode, with a
guard that keeps at least one of the two visible so the app can't strand itself with no way to
open Preferences or quit.

**New app and menu bar icons.** These are this fork's own artwork, not Tyler's — his original
icon is not included here.

## Requirements

macOS 15.7 or later. Requires Accessibility permission (System Settings → Privacy & Security →
Accessibility); the app will prompt and quit if it isn't granted.

## Building

No dependencies, no package manager. Open `FocusBorder.xcodeproj` in Xcode and Run, or:

```bash
xcodebuild -project FocusBorder.xcodeproj -scheme FocusBorder -configuration Debug -destination 'platform=macOS' build
```

There is no test target.

A fresh clone builds as-is — no signing setup required. The build is unsigned, which is fine for
running it locally, though macOS treats each rebuild as a new app and will ask you to grant
Accessibility permission again.

To sign with your own Apple Developer team, copy the example config and fill in your team id:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` is gitignored. No development team is committed to this repo, on purpose
— a committed `DEVELOPMENT_TEAM` signs every clone with somebody else's identity.

Note that this fork uses the bundle id `com.iclassicnu.FocusBorder` rather than upstream's
`studio.retina.Alan`, deliberately — it means this build and upstream's can coexist without
either one taking over the other's Accessibility grant or preferences.
