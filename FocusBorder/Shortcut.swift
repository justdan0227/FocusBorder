//
//  Shortcut.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import Carbon.HIToolbox

// A key equivalent stored in UserDefaults as two integers. Cocoa modifier flags are stored
// rather than Carbon ones because that is what NSEvent hands us; the Carbon translation
// happens once, at registration time (see GlobalHotKey).
struct Shortcut: Equatable {

    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let defaultToggle = Shortcut(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift])

    // Only these four count. Anything else (caps lock, function, the numeric pad bit) would
    // make two otherwise-identical shortcuts compare unequal.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Shortcut.relevantModifiers)
    }

    // A bare letter would swallow every keystroke in every app, so at least one of
    // command/control/option is required. Shift alone does not qualify.
    var isValid: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Shortcut.keyName(for: keyCode)
    }

    // MARK: - Persistence

    // Key code -1 means "no shortcut". Removing the key instead would let the registered
    // default (⌘⇧1) come straight back, so cleared has to be a value, not an absence.
    static let noneKeyCode = -1

    static func load(from defaults: UserDefaults = .standard) -> Shortcut? {
        let code = defaults.integer(forKey: Key.hotKeyCode)
        guard code >= 0 else { return nil }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Key.hotKeyModifiers)))
        return Shortcut(keyCode: UInt16(code), modifiers: flags)
    }

    static func save(_ shortcut: Shortcut?, to defaults: UserDefaults = .standard) {
        defaults.set(shortcut.map { Int($0.keyCode) } ?? noneKeyCode, forKey: Key.hotKeyCode)
        defaults.set(Int(shortcut?.modifiers.rawValue ?? 0), forKey: Key.hotKeyModifiers)
    }

    // MARK: - Key names

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]

    // Asks the current keyboard layout what the key produces unmodified, so a non-US layout
    // shows the label actually printed on the key. Falls back to the raw code if the layout
    // can't be read (input sources without a Unicode layout, e.g. some IMEs).
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return "Key \(keyCode)"
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }

            return UCKeyTranslate(layout,
                                  keyCode,
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  characters.count,
                                  &length,
                                  &characters)
        }

        guard status == noErr, length > 0 else { return "Key \(keyCode)" }

        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
