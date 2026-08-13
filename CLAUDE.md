# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Alan is a small AppKit utility that draws a colored border around whatever window currently
has keyboard focus on macOS. Single Xcode app target, no dependencies, no test target, no
package manager. Deployment target macOS 15.7, Swift 5, bundle id `studio.retina.Alan`.
The upstream README describes it as "more software satire than useful utility" — treat it
as a small toy app, not a production codebase.

## Build & run

```bash
xcodebuild -project Alan.xcodeproj -scheme Alan -configuration Debug -destination 'platform=macOS' build
cp -R ~/Library/Developer/Xcode/DerivedData/Alan-*/Build/Products/Debug/Alan.app /Applications/
open -a /Applications/Alan.app
```

There are no tests and no lint config; `xcodebuild test` will fail (no test target).
Normal workflow is opening `Alan.xcodeproj` in Xcode and hitting Run.

Signing was re-pointed from the upstream author's team to this machine's: `DEVELOPMENT_TEAM`
is `4KGAF7A4WR` (iClassicNu) and the bundle id is `com.iclassicnu.Alan`, matching the
convention in `~/Projects/react_upcheck`. The bundle id had to change — automatic signing
cannot register upstream's `studio.retina.Alan` under a different team. If you pull upstream
changes to `project.pbxproj`, expect to re-apply both.

The app is installed to `/Applications/Alan.app` so the Accessibility grant survives
DerivedData cleans. Running straight out of DerivedData works but the grant is tied to the
path, so it has to be re-approved whenever that path changes.

Running the app requires Accessibility permission. `AppDelegate.requestAccessibilityPermissionIfNeeded()`
opens System Settings and quits if the process isn't trusted. After a rebuild, macOS often
sees the newly-signed binary as a different app, so permission must be re-granted (remove and
re-add the app under Privacy & Security → Accessibility). A build that "does nothing" is almost
always this, not a code bug.

## Architecture

The whole app is four moving parts:

- `FocusHighlighter` (singleton) — the engine. It **polls** the Accessibility API on a 0.1s
  `Timer` rather than subscribing to AX notifications; each tick reads
  `kAXFocusedUIElementAttribute` off the system-wide element, walks up to its `kAXWindow`,
  reads `AXFrame`, and only touches the window when the frame actually changed. If no focused
  frame can be read, the highlight is ordered out.
- Coordinate flip — AX rects are top-left-origin across the whole display arrangement; Cocoa
  is bottom-left. `cocoaRect(fromAXRect:)` flips Y using `max` of all `NSScreen.frame.maxY`,
  not the main screen's height. This is deliberate: using the main screen breaks windows on
  secondary displays (see commit 558034d). Don't "simplify" it back to `NSScreen.main`.
- `HighlightWindow` / `HighlightView` — a borderless, transparent, click-through
  (`ignoresMouseEvents`) window that joins all Spaces. Its window `level` was tuned so the
  border doesn't paint over popup menus (commit ebdaad7); changing it is a regression risk.
  `HighlightView.draw` reads the current prefs from `UserDefaults` on every draw, so there is
  no state to invalidate — clamps inset and width to 1...20 and picks the light/dark color via
  `NSAppearance.isLightMode`.
- `PrefsWindowController` (xib-based) — the settings window. Colors and the two checkboxes use
  `@IBAction`s; width and inset use bindings (see Preferences below). It observes
  `UserDefaults.didChangeNotification` to call `FocusHighlighter.forceUpdate()`, which
  re-applies the last known frame so the border redraws immediately.
- `AppDelegate` also owns the menu bar `NSStatusItem` and the activation policy.
  `applicationShouldHandleReopen` maps a Dock click to `showPrefs:` — necessary because Alan
  has no main window, so a Dock click would otherwise do nothing. `showPrefs:` calls
  `NSApp.activate()` first; without it the window opens behind the frontmost app whenever
  Alan is running as `.accessory`.

## Preferences

All settings live in `UserDefaults` under the keys in `Constants.swift`, registered with
defaults in `applicationDidFinishLaunching`. The Preferences window (Alan menu → Preferences…,
⌘,) exposes all four visual settings: `width` and `inset` as text field + stepper, and
`lightMode`/`darkMode` as color wells.

Width and inset are wired with **Cocoa Bindings** to the `userDefaultsController` object in the
xib (`values.width`, `values.inset`) — not with `@IBAction`/`@IBOutlet`. Grepping
`PrefsWindowController.swift` or searching the xib for `action selector=` will therefore make
them look unimplemented. Only the color wells use actions, because archived `NSColor` needs the
manual `setColor(_:forKey:)` round-trip that bindings can't do.

Two checkboxes cover presentation: **Show icon in menu bar** (`showMenuBarIcon`, default true)
and **Hide from Dock** (`hideDock`, default false). Both apply live via
`AppDelegate.applyMenuBarVisibility()` / `applyDockVisibility()` — no relaunch needed.

`PrefsWindowController.keepAppReachable(preferring:)` enforces an invariant worth preserving:
**at least one of the Dock icon or the menu bar icon must stay visible.** Turning off both
would leave a running app with no way to open Preferences or quit it, short of Activity
Monitor. Whichever setting the user did not just touch is forced back on.

Adding a row to the prefs grid means adding a `gridRow` plus one `gridCell` per column (three),
even for empty cells, and growing the window's `contentRect` — the window is not resizable, so
a too-short window silently clips the new row.

The steppers are constrained to `1...20` to match the clamp in `HighlightView.draw`. If you
change that clamp, change `minValue`/`maxValue` on both `stepperCell`s in the xib to match.
The paired text fields are *not* constrained — their `numberFormatter` has no minimum or
maximum, so a typed value outside `1...20` is still written to `UserDefaults` and then silently
clamped at draw time.

Colors are stored as archived `NSColor` via the `UserDefaults.setColor/color(forKey:)`
extension (legacy `NSKeyedUnarchiver.unarchiveObject`, deprecated but functional).

## Conventions

Plain AppKit + xibs, no SwiftUI, no Storyboards. Files carry the original author's header
comment block; match that style when adding files. The AX code in
`FocusHighlighter.currentFocusedWindowFrame()` uses force-casts on `CFTypeRef` — that's the
prevailing idiom here, but any change to it should keep the existing guard-and-return-nil
error handling rather than crashing on an unexpected attribute type.
