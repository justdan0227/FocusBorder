//
//  PrefsWindowController.swift
//  Alan
//
//  Created by Tyler Hall on 11/26/25.
//

import AppKit

class PrefsWindowController: NSWindowController {
    
    @IBOutlet weak var lightModeColorWell: NSColorWell!
    @IBOutlet weak var darkModeColorWell: NSColorWell!
    @IBOutlet weak var menuBarIconCheckbox: NSButton!
    @IBOutlet weak var hideDockCheckbox: NSButton!

    private var appDelegate: AppDelegate? {
        return NSApp.delegate as? AppDelegate
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        lightModeColorWell.color = UserDefaults.standard.color(forKey: Key.lightMode) ?? Defaults.lightModeColor
        darkModeColorWell.color = UserDefaults.standard.color(forKey: Key.darkMode) ?? Defaults.darkModeColor

        menuBarIconCheckbox.state = UserDefaults.standard.bool(forKey: Key.showMenuBarIcon) ? .on : .off
        hideDockCheckbox.state = UserDefaults.standard.bool(forKey: Key.hideDock) ? .on : .off

        NotificationCenter.default.addObserver(self, selector: #selector(PrefsWindowController.userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @IBAction func lightModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.lightMode)
    }
    
    @IBAction func darkModeChanged(_ sender: NSColorWell) {
        UserDefaults.standard.setColor(sender.color, forKey: Key.darkMode)
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
