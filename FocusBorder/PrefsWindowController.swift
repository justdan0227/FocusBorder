//
//  PrefsWindowController.swift
//  FocusBorder
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

class PrefsWindowController: NSWindowController, NSWindowDelegate {

    @IBOutlet weak var lightModeSwatches: ColorSwatchPicker!
    @IBOutlet weak var darkModeSwatches: ColorSwatchPicker!
    @IBOutlet weak var menuBarIconCheckbox: NSButton!
    @IBOutlet weak var hideDockCheckbox: NSButton!
    @IBOutlet weak var hoverCheckbox: NSButton!
    @IBOutlet weak var shortcutButton: ShortcutRecorderButton!

    private var appDelegate: AppDelegate? {
        return NSApp.delegate as? AppDelegate
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        lightModeSwatches.selectedColor = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        darkModeSwatches.selectedColor = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor

        // Wired here rather than in the xib: Interface Builder only offers action connections
        // on controls it knows about, and these are plain custom views to it.
        lightModeSwatches.target = self
        lightModeSwatches.action = #selector(lightModeChanged(_:))
        darkModeSwatches.target = self
        darkModeSwatches.action = #selector(darkModeChanged(_:))

        menuBarIconCheckbox.state = UserDefaults.standard.bool(forKey: Key.showMenuBarIcon) ? .on : .off
        hideDockCheckbox.state = UserDefaults.standard.bool(forKey: Key.hideDock) ? .on : .off
        hoverCheckbox.state = UserDefaults.standard.bool(forKey: Key.highlightUnderPointer) ? .on : .off

        shortcutButton.shortcut = Shortcut.load()

        window?.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(PrefsWindowController.userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    // This is the app's only window, so holding activation after it closes leaves FocusBorder
    // frontmost with nothing on screen. That is not merely untidy: mouse-moved events go to the
    // active app alone, so while FocusBorder holds activation the global monitor that drives
    // hover mode receives nothing at all. Handing activation back is the real fix; the polled
    // cursor comparison in FocusHighlighter.updateFromPointer is the backstop for every other
    // way the app can end up active. `deactivate` rather than `hide(_:)` — hiding would order
    // out the border window too.
    func windowWillClose(_ notification: Notification) {
        NSApp.deactivate()
    }

    @IBAction func lightModeChanged(_ sender: ColorSwatchPicker) {
        guard let color = sender.selectedColor else { return }
        UserDefaults.standard.setColor(color, forKey: Key.lightMode)
    }

    @IBAction func darkModeChanged(_ sender: ColorSwatchPicker) {
        guard let color = sender.selectedColor else { return }
        UserDefaults.standard.setColor(color, forKey: Key.darkMode)
    }

    @IBAction func highlightUnderPointerChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.highlightUnderPointer)
        FocusHighlighter.shared.modeChanged()
    }

    @IBAction func shortcutChanged(_ sender: ShortcutRecorderButton) {
        Shortcut.save(sender.shortcut)
        appDelegate?.applyHotKey()
    }

    @IBAction func menuBarIconChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.showMenuBarIcon)
        keepAppReachable(preferring: Key.showMenuBarIcon)
        appDelegate?.applyMenuBarVisibility()
    }

    @IBAction func hideDockChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Key.hideDock)
        keepAppReachable(preferring: Key.hideDock)
        appDelegate?.applyDockVisibility()
    }

    // With no Dock icon and no menu bar icon there is no way left to open Preferences or quit,
    // so whichever setting the user did not just touch gets forced back on.
    private func keepAppReachable(preferring justChanged: String) {
        let dockHidden = UserDefaults.standard.bool(forKey: Key.hideDock)
        let menuBarHidden = !UserDefaults.standard.bool(forKey: Key.showMenuBarIcon)

        guard dockHidden && menuBarHidden else { return }

        if justChanged == Key.hideDock {
            UserDefaults.standard.set(true, forKey: Key.showMenuBarIcon)
            menuBarIconCheckbox.state = .on
            appDelegate?.applyMenuBarVisibility()
        } else {
            UserDefaults.standard.set(false, forKey: Key.hideDock)
            hideDockCheckbox.state = .off
            appDelegate?.applyDockVisibility()
        }
    }

    @objc func userDefaultsChanged() {
        FocusHighlighter.shared.forceUpdate()
    }
}
