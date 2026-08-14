//
//  FocusHighlighter.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import ApplicationServices
import os

// Diagnostics for the drag path. Read with:
//   log show --last 2m --info --predicate 'subsystem == "com.iclassicnu.FocusBorder"'
private let log = Logger(subsystem: "com.iclassicnu.FocusBorder", category: "focus")

class FocusHighlighter {

    static let shared = FocusHighlighter()

    private let systemWideElement = AXUIElementCreateSystemWide()
    private let highlightWindow = HighlightWindow()
    private var fallbackTimer: Timer?
    private var lastFrame: CGRect?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedWindow: AXUIElement?

    // Drag sampling. AX move notifications are coalesced to ~10Hz system-wide, which is far too
    // coarse to follow a drag, so while the mouse is down the position is read straight from the
    // WindowServer instead. That is not throttled and never calls into the dragged app.
    private var mouseMonitor: Any?
    private var dragSampler: Timer?
    private var draggedWindowID: CGWindowID?
    private var lastAXFrame: CGRect?
    private var sampleCount = 0
    private var tickCount = 0
    private var lastSampleTime: TimeInterval = 0

    // Hover dwell. Without it the border flashes through every window the pointer crosses on
    // its way somewhere else; 100ms is long enough to ignore transit, short enough to still
    // read as instant when you actually land on a window.
    private let hoverDwell: TimeInterval = 0.1
    private var dwellTimer: Timer?
    private var currentHoverWindowID: CGWindowID?
    private var pendingHoverWindowID: CGWindowID?

    // Auto-hide. When focus lands on a window the border shows for `hideAfterSeconds`
    // (default 5; 0 = never). The one-shot timer is armed once per target — frame-only
    // reapplies (AX move/resize, the 0.5s fallback, drag samples) never re-arm it. On fire
    // the border hides until focus moves to a *different* window; `suppressedWindow` records
    // which window is hidden so same-window reapplies cannot re-show it.
    private var hideTimer: Timer?
    private var suppressedWindow: AXUIElement?

    // Hover auto-hide. Focus mode keys the countdown to the focused window, which hover mode has
    // no equivalent of — the pointer retargets constantly, so a per-window countdown would strobe.
    // The trigger here is pointer *idle* instead: the border hides once the pointer has been still
    // for `hideAfterSeconds`, and any movement re-shows it and restarts the countdown.
    private var hoverIdleTimer: Timer?
    private var hoverSuppressed = false
    private var lastPointerMoveTime: TimeInterval = 0
    private var lastPointerLocation: CGPoint?

    private var hideAfterSeconds: Int {
        UserDefaults.standard.integer(forKey: Key.hideAfterSeconds)
    }

    func start() {
        refreshTarget()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTarget()
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }

            // Every branch below is a real pointer event, which is what distinguishes them from
            // the fallback timer's call into the same method — only these restart the idle
            // countdown and wake an idle-hidden border.
            switch event.type {
            case .leftMouseUp:
                self.endDragSampling()
                if self.hoverEnabled { self.updateFromPointer(pointerMoved: true) }
            case .mouseMoved:
                if self.hoverEnabled { self.updateFromPointer(pointerMoved: true) }
            default:
                // In hover mode the pointer already tracks the dragged window, so the
                // WindowServer sampler is redundant — mouse events arrive just as fast.
                if self.hoverEnabled {
                    self.updateFromPointer(pointerMoved: true)
                } else {
                    self.beginDragSamplingIfNeeded()
                    self.sampleFromDragEvent()
                }
            }
        }

        // Safety net only. The observers below do the real work; this catches apps that never
        // emit AX move/resize notifications, plus Space and display changes, which are not
        // reported at all. Slow on purpose — polling is what made dragging lag.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshTarget()
        }

        if let fallbackTimer {
            RunLoop.current.add(fallbackTimer, forMode: .common)
        }

        // Launching straight into hover mode counts as the pointer having just "arrived", so the
        // border gets one countdown without waiting for the user to jiggle the mouse first.
        if hoverEnabled { noteHoverPointerMoved() }
    }

    // The master on/off switch, driven by the global hotkey and the menu bar item. Every entry
    // point that could show the border checks it, so a disabled app is inert rather than
    // merely hidden — no AX round trips, no drag sampling, no timers.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.enabled)
    }

    func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        UserDefaults.standard.set(enabled, forKey: Key.enabled)
        log.info("enabled = \(enabled, privacy: .public)")

        if enabled {
            // Same bookkeeping reset a mode toggle needs: clean timers, then re-target for
            // whichever mode is currently on.
            modeChanged()
        } else {
            endDragSampling()
            cancelDwell()
            cancelHideTimer()
            cancelHoverIdleTimer()
            currentHoverWindowID = nil
            suppressedWindow = nil
            hoverSuppressed = false
            hideHighlight()
        }
    }

    func forceUpdate() {
        guard isEnabled else { return }
        guard let lastFrame else { return }
        highlightWindow.updateFrame(to: lastFrame, raise: true)
        highlightWindow.redraw()
    }

    fileprivate func handleAXNotification(_ name: String) {
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Only reached outside a drag — these arrive at ~10Hz, and while the WindowServer
            // sampler is running it is strictly ahead of them, so a late AX frame would snap
            // the border backwards.
            guard dragSampler == nil else { return }

            if let observedWindow {
                updateFrame(from: observedWindow)
            }
        default:
            refreshTarget()
        }
    }

    private var hoverEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.highlightUnderPointer)
    }

    // Called when the preference is toggled, so the border re-targets immediately rather than
    // waiting for the next mouse move or focus change.
    func modeChanged() {
        cancelDwell()
        currentHoverWindowID = nil

        // Each mode owns its own auto-hide bookkeeping, and the two are not interchangeable —
        // both must start clean and end clean on a toggle.
        cancelHideTimer()
        suppressedWindow = nil
        cancelHoverIdleTimer()
        hoverSuppressed = false

        if hoverEnabled {
            // Explicit toggle, so commit straight away instead of making the user wiggle the
            // mouse and wait out a dwell.
            commitHoverTarget()
            noteHoverPointerMoved()
        } else {
            refreshTarget()
        }
    }

    // Topmost on-screen window containing the pointer. CGWindowListCopyWindowInfo returns
    // front-to-back, so the first hit is what is visually under the cursor — which is the whole
    // point when windows are stacked. layer == 0 skips the menu bar, Dock, desktop and FocusBorder's
    // own border; the alpha test skips invisible full-screen overlays that would swallow hits.
    // Measured at 0.22ms per call, so running it per mouse-move event is not a concern.
    private func windowUnderPointer(at point: CGPoint? = nil) -> (id: CGWindowID, bounds: CGRect)? {
        guard let point = point ?? CGEvent(source: nil)?.location else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }

        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point)
            else { continue }

            return (number, bounds)
        }

        return nil
    }

    // `pointerMoved` separates the two kinds of caller. Real mouse events pass true: they wake an
    // idle-hidden border and restart the countdown. The 0.5s fallback poll passes false, and must
    // not — otherwise it would resurrect the border twice a second and the hide would never stick.
    //
    // The flag is only a proxy for "did the pointer move", though, and it is not a reliable one:
    // a global NSEvent monitor sees mouse-moved events only while they are being delivered to
    // *another* application, and macOS routes them to the active app alone. So whenever
    // FocusBorder itself is active — Preferences open, or just closed without activation being
    // handed back — the monitor goes silent, and an idle-hidden border could never come back.
    // Comparing the polled cursor position is the direct measurement, so the fallback poll can
    // wake the border when the pointer really has moved and still leave it hidden when it hasn't.
    private func updateFromPointer(pointerMoved: Bool = false) {
        guard isEnabled else { return }

        let point = CGEvent(source: nil)?.location
        var moved = pointerMoved
        if !moved, let point, let last = lastPointerLocation, point != last {
            moved = true
        }
        lastPointerLocation = point

        if moved {
            hoverSuppressed = false
            noteHoverPointerMoved()
        } else if hoverSuppressed {
            return
        }

        let hit = point.flatMap(windowUnderPointer(at:))

        // Still the window already highlighted: track it live and cancel any pending switch.
        // This is keyed on window id rather than bounds on purpose — dragging a window in hover
        // mode changes its bounds every event, and a bounds-keyed dwell would restart its timer
        // forever and never commit.
        if let hit, hit.id == currentHoverWindowID {
            cancelDwell()
            applyHoverBounds(hit.bounds)
            return
        }

        // Same candidate already waiting: let the running timer finish rather than restarting
        // it, or moving around inside the new window would postpone the commit indefinitely.
        if hit?.id == pendingHoverWindowID && dwellTimer != nil { return }

        pendingHoverWindowID = hit?.id
        dwellTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: hoverDwell, repeats: false) { [weak self] _ in
            self?.commitHoverTarget()
        }
        RunLoop.current.add(timer, forMode: .common)
        dwellTimer = timer
    }

    // Re-runs the hit test rather than trusting what was under the pointer when the timer was
    // scheduled — the pointer, and the windows, may have moved during the dwell.
    private func commitHoverTarget() {
        dwellTimer = nil
        pendingHoverWindowID = nil

        guard isEnabled else { return }

        if let hit = windowUnderPointer() {
            currentHoverWindowID = hit.id
            applyHoverBounds(hit.bounds)
        } else {
            currentHoverWindowID = nil
            hideHighlight()
        }
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        pendingHoverWindowID = nil
    }

    private func applyHoverBounds(_ bounds: CGRect) {
        lastAXFrame = bounds

        let cocoaFrame = cocoaRect(fromAXRect: bounds)

        if lastFrame != cocoaFrame {
            lastFrame = cocoaFrame
            highlightWindow.updateFrame(to: cocoaFrame)
        }
    }

    // Works out which window is focused and re-points the observers at it.
    private func refreshTarget() {
        guard isEnabled else { return }

        // In hover mode the pointer decides, so the AX focus path must not fight it — this also
        // catches the fallback timer and any stray AX notification.
        if hoverEnabled {
            updateFromPointer()
            return
        }

        guard let window = currentFocusedWindow() else {
            teardownObserver()
            hideHighlight()
            cancelHideTimer()
            suppressedWindow = nil
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }

        if pid != observedPID {
            teardownObserver()
            setupObserver(for: pid)
        }

        if observedWindow == nil || !CFEqual(observedWindow, window) {
            if let observer, let observedWindow {
                AXObserverRemoveNotification(observer, observedWindow, kAXWindowMovedNotification as CFString)
                AXObserverRemoveNotification(observer, observedWindow, kAXWindowResizedNotification as CFString)
            }

            observedWindow = window

            // New target: a stale pending timer must not fire for the old window, and any
            // suppression from the previous target no longer applies. updateFrame below
            // re-shows and arms the countdown.
            cancelHideTimer()
            suppressedWindow = nil

            if let observer {
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                let moved = AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
                let resized = AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
                log.info("observing pid \(pid, privacy: .public) moved=\(moved.rawValue, privacy: .public) resized=\(resized.rawValue, privacy: .public)")
            }
        }

        updateFrame(from: window, raise: true)
    }

    private func setupObserver(for pid: pid_t) {
        var newObserver: AXObserver?

        guard AXObserverCreate(pid, focusObserverCallback, &newObserver) == .success,
              let newObserver else {
            log.error("AXObserverCreate FAILED for pid \(pid, privacy: .public)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // App-level notifications tell us when to re-resolve which window to follow.
        for name in [kAXFocusedWindowChangedNotification,
                     kAXFocusedUIElementChangedNotification,
                     kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(newObserver, app, name as CFString, refcon)
        }

        // .commonModes matters — with .defaultMode the border would freeze mid-drag, because
        // dragging runs the main loop in event tracking mode.
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )

        observer = newObserver
        observedPID = pid
    }

    private func teardownObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observer = nil
        observedWindow = nil
        observedPID = 0
    }

    private func updateFrame(from window: AXUIElement, raise: Bool = false) {
        // Auto-hide suppression: this window's border is hidden until focus moves on. One
        // guard covers both callers — the AX move/resize hot path and refreshTarget's
        // raise:true re-show — so the fallback timer, stale notifications and forceUpdate
        // cannot resurrect a timer-hidden border.
        if let suppressedWindow, CFEqual(suppressedWindow, window) {
            return
        }

        guard let axFrame = frame(of: window) else {
            hideHighlight()
            return
        }

        lastAXFrame = axFrame

        let cocoaFrame = cocoaRect(fromAXRect: axFrame)

        if lastFrame != cocoaFrame || raise {
            lastFrame = cocoaFrame
            highlightWindow.updateFrame(to: cocoaFrame, raise: raise)
        }

        armHideTimerIfNeeded(for: window)
    }

    // Arms only when nothing is already pending, so a frame reapply on a visible border never
    // restarts the countdown. New targets, drag end, and mode toggles all arrive here with
    // hideTimer == nil (they cancel first), so each gets a fresh countdown.
    private func armHideTimerIfNeeded(for window: AXUIElement) {
        guard hideTimer == nil, highlightWindow.isVisible else { return }

        let seconds = hideAfterSeconds
        guard seconds > 0 else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            self?.hideTimerFired(for: window, after: seconds)
        }
        RunLoop.current.add(timer, forMode: .common)
        hideTimer = timer

        log.info("auto-hide: armed \(seconds, privacy: .public)s timer")
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func hideTimerFired(for window: AXUIElement, after seconds: Int) {
        hideTimer = nil

        // The pref changed to 0 (never) while the countdown ran — don't hide after all.
        guard hideAfterSeconds > 0 else { return }

        // The target changed while the timer was running; the new target's own countdown
        // supersedes this one. (The new-target branch already cancels the pending timer, so
        // this is belt-and-braces.)
        guard let observedWindow, CFEqual(observedWindow, window) else { return }

        suppressedWindow = observedWindow
        hideHighlight()
        log.info("auto-hide: fired after \(seconds, privacy: .public)s; hidden until focus changes")
    }

    // Stamping a timestamp rather than rescheduling is deliberate: mouse-moved events arrive at
    // 60-120Hz, so restarting a Timer on each one would churn an object per event. Instead the
    // timer is armed once and reschedules itself for whatever idle time is left when it fires.
    private func noteHoverPointerMoved() {
        lastPointerMoveTime = ProcessInfo.processInfo.systemUptime

        guard hoverIdleTimer == nil else { return }
        scheduleHoverIdleTimer(after: TimeInterval(hideAfterSeconds))
    }

    private func scheduleHoverIdleTimer(after delay: TimeInterval) {
        guard delay > 0 else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hoverIdleTimerFired()
        }
        RunLoop.current.add(timer, forMode: .common)
        hoverIdleTimer = timer
    }

    private func cancelHoverIdleTimer() {
        hoverIdleTimer?.invalidate()
        hoverIdleTimer = nil
    }

    private func hoverIdleTimerFired() {
        hoverIdleTimer = nil

        // The mode was switched, or the pref set to 0 (never), while the countdown ran.
        guard hoverEnabled else { return }
        let seconds = TimeInterval(hideAfterSeconds)
        guard seconds > 0 else { return }

        let idle = ProcessInfo.processInfo.systemUptime - lastPointerMoveTime
        if idle < seconds {
            scheduleHoverIdleTimer(after: seconds - idle)
            return
        }

        hoverSuppressed = true
        hideHighlight()
        log.info("auto-hide: pointer idle \(seconds, privacy: .public)s; hidden until it moves")
    }

    private func beginDragSamplingIfNeeded() {
        guard isEnabled else { return }
        guard dragSampler == nil else { return }
        guard let windowID = resolveDraggedWindowID() else { return }

        // The border must stay up for the whole drag: kill any pending countdown and drop
        // any suppression. endDragSampling -> refreshTarget() re-shows and re-arms on
        // mouse-up. If the border is already timer-hidden this never runs —
        // resolveDraggedWindowID needs lastAXFrame, which hideHighlight niled — so a
        // same-window drag cannot resurrect it, which is the decided behavior.
        cancelHideTimer()
        suppressedWindow = nil

        draggedWindowID = windowID
        sampleCount = 0
        tickCount = 0

        // 120Hz so the border keeps up on ProMotion displays. Each tick is a WindowServer
        // lookup for a single window id, which is far cheaper than an AX round trip.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.sampleDraggedWindow()
        }
        RunLoop.current.add(timer, forMode: .common)
        dragSampler = timer

        // The timer's first fire is a full interval away; the window is moving *now*.
        sampleDraggedWindow()
    }

    // Called for every .leftMouseDragged while the sampler runs. The events mark the moment
    // the window actually moved, so sampling here shaves up to a full timer interval of
    // staleness off what the next composite shows; the timer keeps running to cover coalesced
    // or dropped events. The 3ms guard just stops event + tick from doubling the WindowServer
    // traffic for no visible gain.
    private func sampleFromDragEvent() {
        guard dragSampler != nil else { return }
        guard ProcessInfo.processInfo.systemUptime - lastSampleTime >= 0.003 else { return }
        sampleDraggedWindow()
    }

    private func endDragSampling() {
        guard dragSampler != nil else { return }

        dragSampler?.invalidate()
        dragSampler = nil
        draggedWindowID = nil

        log.info("drag ended: \(self.sampleCount, privacy: .public) samples from \(self.tickCount, privacy: .public) attempts (timer + events)")

        // Hand back to the AX path, which is authoritative once the drag is over.
        refreshTarget()
    }

    // Matches the tracked AX window to a WindowServer window id by pid and geometry. Only the
    // geometry keys are used, so this needs no Screen Recording permission — window *names*
    // would, but those are never read.
    //
    // Nearest-geometry, not exact: by the time the first .leftMouseDragged reaches the global
    // monitor the window has already moved with the cursor, and lastAXFrame only refreshes at
    // the ~10Hz AX cadence — an exact ±2px match therefore misses for the first ~100ms of every
    // real drag (measured: 14 straight misses over 106ms) and leaves the drag start on the 10Hz
    // path. Requiring overlap with the stale frame and taking the closest candidate attaches on
    // the first event, and still resolves to the same window an exact match would (its distance
    // is ~0), so the app's other windows lose the tie.
    private func resolveDraggedWindowID() -> CGWindowID? {
        guard observedPID != 0, let axFrame = lastAXFrame else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }

        var bestID: CGWindowID?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == observedPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.intersects(axFrame)
            else { continue }

            let distance = abs(bounds.origin.x - axFrame.origin.x)
                + abs(bounds.origin.y - axFrame.origin.y)
                + abs(bounds.width - axFrame.width)
                + abs(bounds.height - axFrame.height)

            if distance < bestDistance {
                bestDistance = distance
                bestID = number
            }
        }

        if let bestID {
            log.info("drag sampling window \(bestID, privacy: .public) pid \(self.observedPID, privacy: .public) offset \(Int(bestDistance), privacy: .public)px")
            return bestID
        }

        log.info("drag sampling: no WindowServer match for pid \(self.observedPID, privacy: .public)")
        return nil
    }

    private func sampleDraggedWindow() {
        tickCount += 1
        lastSampleTime = ProcessInfo.processInfo.systemUptime

        // .optionIncludingWindow takes the id directly. CGWindowListCreateDescriptionFromArray
        // looks like the natural fit but silently returns nothing from Swift: it wants the ids
        // as raw pointer values, and `[windowID] as CFArray` bridges them to CFNumbers.
        guard let windowID = draggedWindowID,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return }

        sampleCount += 1
        lastAXFrame = bounds

        let cocoaFrame = cocoaRect(fromAXRect: bounds)

        if lastFrame != cocoaFrame {
            lastFrame = cocoaFrame
            highlightWindow.updateFrame(to: cocoaFrame)
        }
    }

    private func hideHighlight() {
        if highlightWindow.isVisible {
            highlightWindow.orderOut(nil)
            lastFrame = nil
            lastAXFrame = nil
        }
    }

    // Hello, darkness, my old friend. I'm still really bad at this API.
    private func currentFocusedWindow() -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard err == .success, let element = focusedElement as! AXUIElement? else {
            return nil
        }

        // If focus is a child, ask for its window
        var windowElement: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowElement
        )

        if windowErr == .success, let w = windowElement as! AXUIElement? {
            return w
        }

        return element
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var frameValue: CFTypeRef?
        let frameErr = AXUIElementCopyAttributeValue(
            element,
            "AXFrame" as CFString,
            &frameValue
        )

        guard frameErr == .success,
              let cfValue = frameValue,
              CFGetTypeID(cfValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var rect = CGRect.zero
        if AXValueGetType(cfValue as! AXValue) == .cgRect {
            AXValueGetValue(cfValue as! AXValue, .cgRect, &rect)
            return rect
        }

        return nil
    }
}

// Must stay nonisolated to convert to the C function pointer AXObserverCreate wants. The run
// loop source is added on the main run loop, so the callback always arrives on the main thread.
private nonisolated func focusObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }

    let highlighter = Unmanaged<FocusHighlighter>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String

    MainActor.assumeIsolated {
        highlighter.handleAXNotification(name)
    }
}

private func cocoaRect(fromAXRect axRect: CGRect) -> CGRect {
    // Find the maximum Y coordinate across all screens in Cocoa space
    // This represents the total height of the entire screen arrangement
    // AX coordinates start from y=0 at the top of the topmost screen
    // Cocoa coordinates start from y=0 at the bottom of the bottommost screen
    // So we need the total height to properly flip the Y coordinate
    let maxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0

    var rect = axRect
    rect.origin.y = maxY - (axRect.origin.y + axRect.height)

    return rect
}
