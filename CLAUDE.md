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

- `FocusHighlighter` (singleton) — the engine, driven by `AXObserver` notifications. An
  observer is created per focused-app pid; app-level notifications
  (`kAXFocusedWindowChanged`, `kAXFocusedUIElementChanged`, miniaturize/deminiaturize) trigger
  `refreshTarget()`, which re-resolves the focused window and re-points the observers, while
  `kAXWindowMoved`/`kAXWindowResized` on the window itself take a hot path that only recomputes
  the frame. `NSWorkspace.didActivateApplicationNotification` covers app switches.

  Two details are load-bearing. The run loop source is added with **`.commonModes`** — with
  `.defaultMode` the border freezes mid-drag, because dragging runs the main loop in event
  tracking mode. And `focusObserverCallback` must stay a `nonisolated` global function, since
  `AXObserverCreate` takes a C function pointer, which a `@MainActor` function cannot convert
  to; it re-enters isolation via `MainActor.assumeIsolated`.

  A 0.5s `fallbackTimer` remains as a safety net for apps that never emit AX move/resize
  notifications and for Space/display changes, which are not reported at all. **If dragging
  ever feels laggy again at roughly half-second granularity, the observers failed to register
  and the fallback is carrying it** — that is the symptom to look for, not a reason to speed
  the timer back up.

### Why drags do not use the AX path

**AX move notifications are coalesced to ~10Hz system-wide.** This was measured, not guessed:
Finder delivered them at exactly 100ms intervals (10.0Hz) and Warp at 117ms (8.5Hz). That cap
is the reason the border visibly trailed a dragged window, and it is unfixable from the AX
side — an earlier attempt replaced 0.1s polling with observers and changed nothing, because
both land at ~10Hz.

So while the left mouse button is down, position comes from the **WindowServer** instead. A
global `NSEvent` monitor starts a 120Hz sampler on the first `.leftMouseDragged`;
`resolveDraggedWindowID()` matches the tracked AX window to a `CGWindowID` by pid and geometry
(no private API), and each tick reads bounds via
`CGWindowListCopyWindowInfo([.optionIncludingWindow], id)`. Measured at ~117Hz sustained with a
100% lookup rate. On `.leftMouseUp` the sampler stops and AX becomes authoritative again.

Two traps, both of which cost a debugging round:

- **Do not use `CGWindowListCreateDescriptionFromArray`.** It wants window ids as raw pointer
  values; `[windowID] as CFArray` bridges them to `CFNumber`s, so it silently returns nothing.
  The symptom is nastier than a plain failure — starting the sampler suppresses the AX path, so
  a silently-failing sampler freezes the border until mouse-up.
- Only geometry keys are read from the window list. Reading `kCGWindowName` would drag in a
  Screen Recording permission prompt for no benefit.

The `os.Logger` calls under subsystem `com.iclassicnu.Alan` are deliberately kept for this —
drag start, sample/tick counts, and observer registration results. They are what turned two
rounds of guessing into a measurement:

```bash
# note: /usr/bin/log — zsh has its own `log` builtin that shadows it
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.iclassicnu.Alan"' --style compact
```
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

**Highlight window under pointer** (`highlightUnderPointer`, default false) switches the border
from following keyboard focus to following the pointer — the point being to find a window
buried under others. `windowUnderPointer()` takes the first `layer == 0`, non-transparent
window containing the cursor from the front-to-back `CGWindowListCopyWindowInfo` ordering.
Measured at 0.22ms per call, so running it per mouse-move event is not a concern; the `layer`
and alpha filters are what keep the menu bar, Dock, desktop, Alan's own border, and invisible
full-screen overlays from swallowing every hit.

While hover mode is on, `refreshTarget()` returns early into `updateFromPointer()` so the AX
focus path cannot fight the pointer, and the drag sampler is skipped entirely — mouse events
already arrive faster than it would sample.

The 100ms dwell (`hoverDwell`) stops the border flashing through every window the pointer
merely crosses. **It is keyed on window id, not bounds, and that is not incidental:** dragging
a window changes its bounds on every event, so a bounds-keyed dwell would restart its timer
forever and never commit — the border would freeze for the whole drag. Staying inside one
window tracks it live; only switching windows waits.

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

## Relationship to upstream

`origin` is `tylerhall/Alan` — the original author's repo, not a fork you can push to. All work
here is local commits on `main`. Upstream was last seen at `ebdaad7`.

Some commits are **fork-local and must never be sent upstream**:

- `f17569c` (signing) — points `DEVELOPMENT_TEAM` at `4KGAF7A4WR` and renames the bundle to
  `com.iclassicnu.Alan`. Upstream this would sign the maintainer's app with the wrong team and
  orphan every existing user's Accessibility grant and preferences domain.
- `CLAUDE.md` — this file.
- The `Key.width` default of 1 (upstream ships 5). Taste, not a fix, and currently tangled
  inside the menu bar commit `967f654` rather than standing alone.
- The `os.Logger` diagnostics — the subsystem is hardcoded to `com.iclassicnu.Alan`. Strip them
  or derive from `Bundle.main.bundleIdentifier` before any upstream branch.

A PR-able branch is therefore `d19c7f6` + `58fdcae` (the drag lag fix) cherry-picked onto
`ebdaad7` with the logging removed — roughly +180 lines in two files. The measured ~10Hz AX
finding in `58fdcae`'s commit message is the substance of that contribution. Note the upstream
README describes the project as "more software satire than useful utility", so open an issue
and ask before investing in a PR.
