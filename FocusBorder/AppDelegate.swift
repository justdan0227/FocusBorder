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

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        UserDefaults.standard.register(defaults: [
            Key.width: 1,
            Key.inset: 4,
            Key.hideDock: false,
            Key.showMenuBarIcon: true,
            Key.highlightUnderPointer: false,
            Key.hideAfterSeconds: 5,
            Key.lightMode: Defaults.lightModeColor,
            Key.darkMode: Defaults.darkModeColor
        ])

        applyDockVisibility()
        applyMenuBarVisibility()

        requestAccessibilityPermissionIfNeeded()

        FocusHighlighter.shared.start()
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

    @IBAction func showPrefs(_ sender: AnyObject?) {
        // Required when running as .accessory — an app with no Dock icon is not activated by
        // the menu bar click, so the window would open behind whatever is already frontmost.
        NSApp.activate()
        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(nil)
    }
}
