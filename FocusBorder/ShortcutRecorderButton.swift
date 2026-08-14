//
//  ShortcutRecorderButton.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit
import Carbon.HIToolbox

// A push button that records a key equivalent. Click it, press a combination, and `shortcut`
// updates and the action fires. Escape cancels, Delete clears.
class ShortcutRecorderButton: NSButton {

    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }

    private var isRecording = false {
        didSet { updateTitle() }
    }

    // While recording, keystrokes must not reach the rest of the app — Cmd-based combinations
    // are dispatched as key equivalents down the window's view tree before any keyDown, so
    // that is where they have to be intercepted, not in keyDown.
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func awakeFromNib() {
        super.awakeFromNib()
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        updateTitle()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func startRecording() {
        guard !isRecording else { return }

        window?.makeFirstResponder(self)
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func stopRecording() {
        guard isRecording else { return }

        isRecording = false

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    // Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Modifier presses on their own just update the "Type shortcut…" placeholder — they are
        // swallowed so a lone ⌘ doesn't leak out, but they don't end recording.
        guard event.type == .keyDown else { return true }

        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return true
        }

        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            shortcut = nil
            stopRecording()
            sendAction(action, to: target)
            return true
        }

        let candidate = Shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)

        // Not yet a usable combination (no ⌘/⌃/⌥) — keep waiting rather than recording
        // something that would hijack a bare keystroke system-wide.
        guard candidate.isValid else { return true }

        shortcut = candidate
        stopRecording()
        sendAction(action, to: target)
        return true
    }

    private func updateTitle() {
        if isRecording {
            title = "Type shortcut…"
        } else {
            title = shortcut?.displayString ?? "Click to Record"
        }
    }
}
