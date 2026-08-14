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

Signing was re-pointed from the upstream author's team to this machine's, and the bundle id is
`com.iclassicnu.Alan`, matching the convention in `~/Projects/react_upcheck`. The bundle id had
to change — automatic signing cannot register upstream's `studio.retina.Alan` under a different
team. If you pull upstream changes to `project.pbxproj`, expect to re-apply it.

**`DEVELOPMENT_TEAM` is not in `project.pbxproj` and must not go back in** — the repo is
published, and a committed team id signs every clone with this machine's identity. All four
`XCBuildConfiguration` entries carry a `baseConfigurationReference` to `Config/Shared.xcconfig`,
which `#include?`s the gitignored `Config/Local.xcconfig`; that file holds
`DEVELOPMENT_TEAM = 4KGAF7A4WR`. `Config/Local.xcconfig.example` documents it for others.

The optional-include form matters: a clone with no `Local.xcconfig` still configures and builds
(verified — it produces an unsigned build, which runs fine but re-triggers the Accessibility
grant on every rebuild). Note that xcconfig values lose to build settings written directly into
the target, so if the team ever reappears in `project.pbxproj` it will silently win over
`Local.xcconfig` — check there first if signing goes wrong. Changing the team in Xcode's
Signing & Capabilities UI is exactly what puts it back.

The app is installed to `/Applications/Alan.app` so the Accessibility grant survives
DerivedData cleans. Running straight out of DerivedData works but the grant is tied to the
path, so it has to be re-approved whenever that path changes.

Running the app requires Accessibility permission. `AppDelegate.requestAccessibilityPermissionIfNeeded()`
opens System Settings and quits if the process isn't trusted. After a rebuild, macOS often
sees the newly-signed binary as a different app, so permission must be re-granted (remove and
re-add the app under Privacy & Security → Accessibility). A build that "does nothing" is almost
always this, not a code bug.

On macOS 27 the grant is keyed to the binary's signature: even with a stale
`kTCCServiceAccessibility` row still in the system TCC.db (auth_value=2), a rebuilt binary was
denied at launch (`TCCAccessRequest` → auth_value 0) and quit via the permission alert — remove
and re-add the app rather than trusting an existing entry. `tccutil reset Accessibility
com.iclassicnu.Alan` may also clear the stale entry first. The alert's deep link opens the
universalaccess pane (VoiceOver etc.), not the Privacy & Security → Accessibility permission
list, so navigate there manually.

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

## Icons

Both icons are cut from one source render (a neon rounded-square window frame, with the menu
bar glyph shown beside it as black-on-white and white-on-black badges). The extraction is
scripted, not hand-traced, so it can be redone from a new render:

- **AppIcon** (`Assets.xcassets/AppIcon.appiconset/Icon.png`, single 1024 `512x512@2x` entry)
  is the left panel with its **baked drop shadow stripped** — the body sits at alpha 0.99 and
  the shadow tapers from 0.70 down, so remapping alpha through a narrow ramp at 0.80 removes it
  while leaving a ~2px antialiased edge. Leaving it in would double up with the shadow macOS
  draws itself.
- **MenuBarIcon** (`Assets.xcassets/MenuBarIcon.imageset`, 18pt 1x + 2x) is the glyph lifted out
  of the black-on-white badge: a circular mask keeps the disc edge and surrounding glow out, and
  luminance becomes the alpha channel. `template-rendering-intent` is `template` in
  `Contents.json` **and** `isTemplate = true` in code — a status item drawn non-template ignores
  the menu bar's appearance and stays black on a dark bar. One template covers light and dark,
  so the second badge in the render is reference only, not a second asset.

The artwork is deliberately **full-bleed** (the rounded rect fills the whole 1024 canvas) rather
than sitting on Apple's classic 824/1024 icon grid. On macOS 27 an app shipping only a legacy
`AppIcon` gets its artwork inset onto a system-drawn light plate, so grid margin double-insets
and the icon renders visibly smaller — this was compared both ways. Escaping the plate entirely
would mean shipping an Icon Composer `.icon` asset, which this app does not have.

## Preferences

All settings live in `UserDefaults` under the keys in `Constants.swift`, registered with
defaults in `applicationDidFinishLaunching`. The Preferences window (Alan menu → Preferences…,
⌘,) exposes all five visual settings: `width`, `inset`, and `hideAfterSeconds` as text field +
stepper, and `lightMode`/`darkMode` as color wells.

Width, inset, and hideAfterSeconds are wired with **Cocoa Bindings** to the
`userDefaultsController` object in the xib (`values.width`, `values.inset`,
`values.hideAfterSeconds`) — not with `@IBAction`/`@IBOutlet`. Grepping
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

**Hide after (seconds)** (`hideAfterSeconds`, default 5, 0 = never) auto-hides the border in
focus mode once the focused window has held focus that long. A one-shot `hideTimer` is armed
once per target change — frame-only reapplies (AX move/resize, the 0.5s fallback, drag
samples) never re-arm it. On fire, `hideHighlight()` hides the border and nils
`lastFrame`/`lastAXFrame` (which also makes `forceUpdate()` a no-op while hidden). It stays
hidden until focus moves to a *different* window: `suppressedWindow` is compared with
`CFEqual` in `updateFrame(from:raise:)`, and cleared on target change, focus loss, drag start,
and `modeChanged()`. Drags cancel the pending timer and any suppression so the border never
vanishes mid-drag; `endDragSampling -> refreshTarget()` re-shows and re-arms on mouse-up.
Setting the pref to 0 mid-countdown is honored at fire time (the border stays).

**Hover mode uses the same pref but a different trigger.** There is no discrete target to key a
countdown to — the pointer retargets constantly, so a per-window countdown would strobe. Instead
`hideAfterSeconds` counts *pointer idle*: the border hides once the pointer has been still that
long (`hoverIdleTimer` → `hoverSuppressed`), and any pointer event clears the suppression and
restarts the count. Two things make it work:

- `updateFromPointer(pointerMoved:)` — real mouse events pass `true`, the 0.5s fallback poll
  passes `false`. Without that split the fallback would resurrect the border twice a second and
  the hide would never stick. A `false` call while suppressed returns immediately.
- The countdown is a timestamp (`lastPointerMoveTime`) plus **one** self-rescheduling timer, not
  a timer restarted per event. Mouse-moved arrives at 60–120Hz; restarting a `Timer` on each
  would churn an object per event. On fire it compares elapsed idle against the pref and
  reschedules for the remainder if the pointer moved recently.

Re-showing needs no explicit `orderFront`: `hideHighlight()` nils `lastFrame`, so the next
`applyHoverBounds` always sees a changed frame and `HighlightWindow.updateFrame` calls
`orderFrontRegardless()` on its `!isVisible` branch.

Note that synthetic `CGEvent` mouse moves **cannot** be used to test any of this from a scratch
script — macOS silently drops HID events posted by a process that is not itself Accessibility-
trusted, so the cursor never moves and the test reads as "the border never came back." Verify
hover behavior by hand, or from the `auto-hide: pointer idle` log lines.

Adding a row to the prefs grid means adding a `gridRow` plus one `gridCell` per column (three),
even for empty cells, and growing the window's `contentRect` — the window is not resizable, so
a too-short window silently clips the new row.

The steppers are constrained to `1...20` to match the clamp in `HighlightView.draw`. If you
change that clamp, change `minValue`/`maxValue` on both `stepperCell`s in the xib to match.
The `hideAfterSeconds` stepper is the exception: `0...60` (0 = never hide), and not tied to the
draw clamp.
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
- `44725ec` (icons) — replaces the maintainer's artwork with this fork's own. Taste, and
  replacing a maintainer's icon uninvited lands badly regardless of quality. The artwork is also
  AI-generated, so it is not Tyler's to receive and not covered by his license either way.
- `README.md` and `LICENSE` — the README is rewritten as fork documentation, and the LICENSE
  carries a second copyright line. Both are correct here and wrong upstream.

A PR-able branch is therefore `d19c7f6` + `58fdcae` (the drag lag fix) cherry-picked onto
`ebdaad7` with the logging removed — roughly +180 lines in two files. The measured ~10Hz AX
finding in `58fdcae`'s commit message is the substance of that contribution. Note the upstream
README describes the project as "more software satire than useful utility", so open an issue
and ask before investing in a PR. Hover mode and auto-hide are *features*, not fixes — they need
the maintainer's buy-in before any code, and do not belong in the same PR as the drag fix.

### Publishing this fork

Upstream is MIT. Republishing publicly is permitted outright and needs no permission; the only
binding obligation is the notice clause, so **`LICENSE` must keep Tyler Hall's copyright line**
— Dan's line was added beneath it, not in place of it. The per-file `Created by Tyler Hall`
headers stay for the same reason. If a built `.app` is ever distributed rather than just source,
the license text has to travel with it (a `Credits.rtf` or a bundled `LICENSE` in `Resources`),
because a binary is a "copy of the Software" too.

The bundle id divergence is load-bearing here rather than incidental: `com.iclassicnu.Alan` lets
this build and upstream's coexist without either taking over the other's Accessibility grant or
preferences domain. Do not "fix" it back to `studio.retina.Alan`.
