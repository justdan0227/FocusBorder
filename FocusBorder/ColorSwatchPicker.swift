//
//  ColorSwatchPicker.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

// A grid of fixed color swatches, drawn inline in the Preferences window. This replaces the
// NSColorWell pair: the border only ever needs one flat color out of a short list, and a well
// pushes that choice out into the shared system color panel — a separate floating window, and
// one that has to be configured globally at launch to stay on the basic colors.
class ColorSwatchPicker: NSControl {

    // Apple's crayon values, so the palette matches what the system picker used to offer.
    static let palette: [(name: String, color: NSColor)] = [
        ("Black", NSColor(hex: "000000")),
        ("Gray", NSColor(hex: "808080")),
        ("White", NSColor(hex: "FFFFFF")),
        ("Maraschino", NSColor(hex: "FF2600")),
        ("Tangerine", NSColor(hex: "FF9300")),
        ("Lemon", NSColor(hex: "FFFB00")),
        ("Spring", NSColor(hex: "00F900")),
        ("Turquoise", NSColor(hex: "00FDFF")),
        ("Blueberry", NSColor(hex: "0433FF")),
        ("Grape", NSColor(hex: "9437FF")),
        ("Magenta", NSColor(hex: "FF40FF")),
        ("Mocha", NSColor(hex: "945200"))
    ]

    private static let columns = 6
    private static let swatchSize: CGFloat = 22
    private static let spacing: CGFloat = 6

    // A color from an older build (or an upstream default) need not be in the palette. That
    // draws as simply nothing selected rather than being silently snapped to the nearest
    // swatch — the border keeps the color it has until the user picks a new one.
    var selectedColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let rows = (ColorSwatchPicker.palette.count + ColorSwatchPicker.columns - 1) / ColorSwatchPicker.columns
        return NSSize(width: extent(for: ColorSwatchPicker.columns), height: extent(for: rows))
    }

    private func extent(for count: Int) -> CGFloat {
        CGFloat(count) * ColorSwatchPicker.swatchSize + CGFloat(count - 1) * ColorSwatchPicker.spacing
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        for (index, entry) in ColorSwatchPicker.palette.enumerated() {
            addToolTip(rect(at: index), owner: entry.name as NSString, userData: nil)
        }
    }

    private func rect(at index: Int) -> NSRect {
        let column = index % ColorSwatchPicker.columns
        let row = index / ColorSwatchPicker.columns
        let stride = ColorSwatchPicker.swatchSize + ColorSwatchPicker.spacing

        return NSRect(x: CGFloat(column) * stride,
                      y: CGFloat(row) * stride,
                      width: ColorSwatchPicker.swatchSize,
                      height: ColorSwatchPicker.swatchSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, entry) in ColorSwatchPicker.palette.enumerated() {
            let box = rect(at: index)
            let swatch = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)

            entry.color.setFill()
            swatch.fill()

            // White and the lighter crayons would otherwise dissolve into the window
            // background, so every swatch gets a hairline border.
            NSColor.separatorColor.setStroke()
            swatch.lineWidth = 1
            swatch.stroke()

            guard matches(entry.color, selectedColor) else { continue }

            // The ring sits outside the swatch rather than on top of it, so the selected color
            // is still shown whole. controlAccentColor keeps it legible against any swatch.
            let ring = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard let index = ColorSwatchPicker.palette.indices.first(where: { rect(at: $0).contains(point) }) else {
            return
        }

        selectedColor = ColorSwatchPicker.palette[index].color
        sendAction(action, to: target)
    }

    // Compares in sRGB because the stored color has been through a NSKeyedArchiver round trip
    // and may come back in a different (but equivalent) color space; a componentwise compare on
    // whatever space it lands in would miss.
    private func matches(_ lhs: NSColor, _ rhs: NSColor?) -> Bool {
        guard let rhs,
              let a = lhs.usingColorSpace(.sRGB),
              let b = rhs.usingColorSpace(.sRGB)
        else {
            return false
        }

        let tolerance: CGFloat = 1.0 / 255.0

        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
    }
}
