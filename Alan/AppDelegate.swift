//
//  AppDelegate.swift
//  Alan
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

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        UserDefaults.standard.register(defaults: [
            Key.width: 1,
            Key.inset: 4,
            Key.hideDock: false,
            Key.showMenuBarIcon: true,
            Key.highlightUnderPointer: false,
            Key.lightMode: Defaults.lightModeColor,
            Key.darkMode: Defaults.darkModeColor
        ])

        applyDockVisibility()
        applyMenuBarVisibility()

        requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()
    }

    // Clicking the Dock icon reopens Preferences. Alan has no main window, so without this
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
        let image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Alan")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        let prefsItem = menu.addItem(withTitle: "Preferences…", action: #selector(showPrefs(_:)), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            Alan needs Accessibility permission to highlight the focused window.

            Please open System Settings → Privacy & Security → Accessibility
            and enable “Alan”.

            Then relaunch Alan.
            """
            alert.addButton(withTitle: "Quit")
            alert.runModal()

            NSApp.terminate(nil)
            return
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
