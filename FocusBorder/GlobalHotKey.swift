//
//  GlobalHotKey.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "com.iclassicnu.FocusBorder", category: "hotkey")

// System-wide hotkey via Carbon's RegisterEventHotKey. This is deliberately not an NSEvent
// global monitor: a monitor only observes, so the keystroke would still reach the frontmost
// app, and it would need the Accessibility grant to see modified keys at all. Carbon hotkeys
// are consumed and need no permission.
final class GlobalHotKey {

    static let shared = GlobalHotKey()

    var handler: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let signature = OSType(0x464F4342) // 'FOCB'

    private init() {}

    // Re-registering is the only way to change a Carbon hotkey, so this always tears down first.
    // A nil or invalid shortcut simply leaves nothing registered.
    func register(_ shortcut: Shortcut?) {
        unregister()

        guard let shortcut, shortcut.isValid else {
            log.info("hotkey cleared")
            return
        }

        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                         carbonModifiers(from: shortcut.modifiers),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)

        if status == noErr {
            log.info("hotkey registered: \(shortcut.displayString, privacy: .public)")
        } else {
            // -9868 (eventHotKeyExistsErr) means another app already owns the combination.
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(),
                            hotKeyEventHandler,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    fileprivate func hotKeyPressed() {
        handler?()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

// Must stay a nonisolated global function to convert to the C function pointer
// InstallEventHandler wants — the same constraint focusObserverCallback lives under. Carbon
// dispatches on the main thread, so re-entering isolation is safe.
private nonisolated func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                            _ event: EventRef?,
                                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

    MainActor.assumeIsolated {
        hotKey.hotKeyPressed()
    }

    return noErr
}
