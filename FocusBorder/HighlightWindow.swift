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

    // Hot path during a drag. The stroke lives in a CAShapeLayer, so a move needs no drawing
    // at all, and a resize only re-sets the layer path in layout() — path and frame land in
    // the same CoreAnimation commit, and the stroking happens in the render server, off this
    // app's main thread. Synchronously redrawing a window-sized backing store per sample is
    // what used to throttle resize drags to ~70Hz.
    func updateFrame(to rect: CGRect, raise: Bool = false) {
        let newRect = rect.insetBy(dx: -2, dy: -2)
        let resized = newRect.size != frame.size

        setFrame(newRect, display: false)

        if resized {
            contentView?.needsLayout = true
        }

        // Re-ordering on every move event is likewise wasted work; .statusBar level already
        // keeps the border above ordinary windows between focus changes.
        if raise || !isVisible {
            orderFrontRegardless()
        }
    }

    func redraw() {
        contentView?.needsLayout = true
    }
}

class HighlightView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        CAShapeLayer()
    }

    // Style and geometry are re-read from UserDefaults on every pass, so there is no cached
    // state to invalidate — the same model the old draw(_:) had. AppKit queues layout whenever
    // the view's size changes; everything else (prefs changes via redraw(), appearance and
    // backing-scale changes below) arrives as an explicit needsLayout.
    override func layout() {
        super.layout()

        guard let shape = layer as? CAShapeLayer else { return }

        var inset = UserDefaults.standard.integer(forKey: Key.inset)
        inset = max(1, min(20, inset))

        var width = UserDefaults.standard.integer(forKey: Key.width)
        width = max(1, min(20, width))

        let color: NSColor
        if NSAppearance.isLightMode {
            color = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        } else {
            color = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor
        }

        // A window narrower than twice the inset would produce a negative-size rect.
        let inner = bounds.insetBy(dx: CGFloat(inset), dy: CGFloat(inset))

        // An implicitly animated path is exactly the trailing border this app exists to avoid.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = (inner.width > 0 && inner.height > 0) ? CGPath(rect: inner, transform: nil) : nil
        shape.lineWidth = CGFloat(width)
        shape.strokeColor = color.cgColor
        shape.fillColor = nil
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsLayout = true
    }
}
