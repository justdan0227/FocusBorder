//
//  HighlightWindow.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

class HighlightWindow: NSWindow {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        self.isReleasedWhenClosed = false
        
        self.contentView = HighlightView(frame: .zero)
    }
    
    // Hot path during a drag. A window that only moves needs no redraw at all — the stroke is
    // laid out in bounds coordinates, so it is identical at the new origin. Forcing a
    // synchronous full-window redraw here is what made the border trail the drag.
    func updateFrame(to rect: CGRect, raise: Bool = false) {
        let newRect = rect.insetBy(dx: -2, dy: -2)
        let resized = newRect.size != frame.size

        setFrame(newRect, display: resized)

        if resized {
            contentView?.setNeedsDisplay(.infinite)
        }

        // Re-ordering on every move event is likewise wasted work; .statusBar level already
        // keeps the border above ordinary windows between focus changes.
        if raise || !isVisible {
            orderFrontRegardless()
        }
    }

    func redraw() {
        contentView?.setNeedsDisplay(.infinite)
    }
}

class HighlightView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        var inset = UserDefaults.standard.integer(forKey: Key.inset)
        inset = max(1, min(20, inset))

        var width = UserDefaults.standard.integer(forKey: Key.width)
        width = max(1, min(20, width))

        let path = NSBezierPath(rect: bounds.insetBy(dx: CGFloat(inset), dy: CGFloat(inset)))
        path.lineWidth = CGFloat(width)

        let color: NSColor
        if NSAppearance.isLightMode {
            color = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        } else {
            color = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor
        }
        color.setStroke()

        path.stroke()
    }
}
