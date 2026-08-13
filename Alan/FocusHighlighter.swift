//
//  FocusHighlighter.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import ApplicationServices
import os

// Diagnostics for the drag path. Read with:
//   log show --last 2m --info --predicate 'subsystem == "com.iclassicnu.Alan"'
private let log = Logger(subsystem: "com.iclassicnu.Alan", category: "focus")

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

    func start() {
        refreshTarget()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTarget()
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }

            if event.type == .leftMouseUp {
                self.endDragSampling()
            } else {
                self.beginDragSamplingIfNeeded()
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
    }

    func forceUpdate() {
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

    // Works out which window is focused and re-points the observers at it.
    private func refreshTarget() {
        guard let window = currentFocusedWindow() else {
            teardownObserver()
            hideHighlight()
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
    }

    private func beginDragSamplingIfNeeded() {
        guard dragSampler == nil else { return }
        guard let windowID = resolveDraggedWindowID() else { return }

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
    }

    private func endDragSampling() {
        guard dragSampler != nil else { return }

        dragSampler?.invalidate()
        dragSampler = nil
        draggedWindowID = nil

        log.info("drag ended: \(self.sampleCount, privacy: .public) samples from \(self.tickCount, privacy: .public) ticks")

        // Hand back to the AX path, which is authoritative once the drag is over.
        refreshTarget()
    }

    // Matches the tracked AX window to a WindowServer window id by pid and geometry. Only the
    // geometry keys are used, so this needs no Screen Recording permission — window *names*
    // would, but those are never read.
    private func resolveDraggedWindowID() -> CGWindowID? {
        guard observedPID != 0, let axFrame = lastAXFrame else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == observedPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            if abs(bounds.origin.x - axFrame.origin.x) <= 2,
               abs(bounds.origin.y - axFrame.origin.y) <= 2,
               abs(bounds.width - axFrame.width) <= 2,
               abs(bounds.height - axFrame.height) <= 2 {
                log.info("drag sampling window \(number, privacy: .public) pid \(pid, privacy: .public)")
                return number
            }
        }

        log.info("drag sampling: no WindowServer match for pid \(self.observedPID, privacy: .public)")
        return nil
    }

    private func sampleDraggedWindow() {
        tickCount += 1

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
