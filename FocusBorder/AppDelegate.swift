//
//  AppDelegate.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import Cocoa
import ApplicationServices

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    let prefsWindowController: PrefsWindowController = {
        return PrefsWindowController(windowNibName: String(describing: PrefsWindowController.self))
    }()

    private var statusItem: NSStatusItem?
    private weak var toggleMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        UserDefaults.standard.register(defaults: [
            Key.width: 1,
            Key.inset: 4,
            Key.hideDock: false,
            Key.showMenuBarIcon: true,
            Key.highlightUnderPointer: false,
            Key.hideAfterSeconds: 5,
            Key.lightMode: Defaults.lightModeColor,
            Key.darkMode: Defaults.darkModeColor,
            Key.enabled: true,
            Key.hotKeyCode: Int(Shortcut.defaultToggle.keyCode),
            Key.hotKeyModifiers: Int(Shortcut.defaultToggle.modifiers.rawValue)
        ])

        applyDockVisibility()
        applyMenuBarVisibility()

        GlobalHotKey.shared.handler = { [weak self] in
            FocusHighlighter.shared.toggleEnabled()
            self?.updateToggleMenuItem()
        }
        applyHotKey()

        requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()
    }

    // Re-reads the shortcut preference and re-registers. Called at launch and whenever the
    // recorder in Preferences changes it.
    func applyHotKey() {
        GlobalHotKey.shared.register(Shortcut.load())
        updateToggleMenuItem()
    }

    // Clicking the Dock icon reopens Preferences. FocusBorder has no main window, so without this
    // a Dock click does nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPrefs(nil)
        return true
    }

    func applyDockVisibility() {
        let hidden = UserDefaults.standard.bool(forKey: Key.hideDock)
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
    }

    func applyMenuBarVisibility() {
        guard UserDefaults.standard.bool(forKey: Key.showMenuBarIcon) else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }

        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // The asset is already marked template in its Contents.json, but setting it here too
        // keeps the SF Symbol fallback correct — a status item drawn non-template ignores the
        // menu bar's light/dark appearance and stays black on a dark bar.
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "FocusBorder")
        image?.isTemplate = true
        image?.accessibilityDescription = "FocusBorder"
        item.button?.image = image

        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "Enable Border", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        updateToggleMenuItem()
        menu.addItem(.separator())
        let prefsItem = menu.addItem(withTitle: "Preferences…", action: #selector(showPrefs(_:)), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FocusBorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
    }

    func requestAccessibilityPermissionIfNeeded() {
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        let trusted = AXIsProcessTrustedWithOptions(options)

        guard trusted else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") {
                NSWorkspace.shared.open(url)
            }

            // Give the user a clear message and quit so they can enable it
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
            FocusBorder needs Accessibility permission to highlight the focused window.

            Please open System Settings → Privacy & Security → Accessibility
            and enable “FocusBorder”.

            Then relaunch FocusBorder.
            """
            alert.addButton(withTitle: "Quit")
            alert.runModal()

            NSApp.terminate(nil)
            return
        }
    }

    @IBAction func toggleEnabled(_ sender: AnyObject?) {
        FocusHighlighter.shared.toggleEnabled()
        updateToggleMenuItem()
    }

    // The menu item mirrors the current state and advertises the hotkey. The key equivalent is
    // cosmetic here — Carbon already handles the combination globally — but it is the only place
    // the shortcut is discoverable without opening Preferences.
    func updateToggleMenuItem() {
        guard let toggleMenuItem else { return }

        toggleMenuItem.state = FocusHighlighter.shared.isEnabled ? .on : .off

        // Multi-character names ("Space", "F5") are not valid key equivalents, so those
        // shortcuts simply go unadvertised rather than rendering as garbage.
        let name = Shortcut.load().map { Shortcut.keyName(for: $0.keyCode) } ?? ""

        if let shortcut = Shortcut.load(), shortcut.isValid, name.count == 1 {
            toggleMenuItem.keyEquivalent = name.lowercased()
            toggleMenuItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            toggleMenuItem.keyEquivalent = ""
            toggleMenuItem.keyEquivalentModifierMask = []
        }
    }

    @IBAction func showPrefs(_ sender: AnyObject?) {
        // Required when running as .accessory — an app with no Dock icon is not activated by
        // the menu bar click, so the window would open behind whatever is already frontmost.
        NSApp.activate()
        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(nil)
    }
}
