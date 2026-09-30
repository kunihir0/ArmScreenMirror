import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var controllers: [MainWindowController] = []
    private var picker: DevicePickerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        startServer()
        showPicker()
    }

    /// Start the shared TCP listener once for the whole app. All
    /// streaming windows route through `ConnectionRouter.shared`.
    private func startServer() {
        let router = ConnectionRouter.shared
        if let saved = Keychain.load(), !saved.isEmpty {
            router.password = saved
        } else {
            DispatchQueue.main.async {
                // Defer until after the picker shows, so the password
                // alert lands on a real key window.
                self.controller?.promptForPassword(initial: true)
                    ?? self.promptForPasswordWithoutController()
            }
        }
        do {
            try router.start()
        } catch {
            NSLog("[Server] failed to start: %@", error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "ScreenMirror could not bind port 4878"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func promptForPasswordWithoutController() {
        let alert = NSAlert()
        alert.messageText = "Set up password"
        alert.informativeText = "This password encrypts traffic between iPhone and Mac. Minimum 8 characters."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            let pwd = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if pwd.count >= 8 {
                Keychain.save(pwd)
                ConnectionRouter.shared.password = pwd
                return
            }
        }
        NSApp.terminate(nil)
    }

    /// Show the device picker. If history is empty, skip straight to a
    /// "listen for any" window — first-launch users shouldn't be greeted
    /// by an empty list with no devices to pick.
    private func showPicker() {
        if DeviceHistory.load().isEmpty {
            openStreamingWindow(for: nil)
            return
        }
        let p = DevicePickerWindowController()
        p.onSelect = { [weak self] picks in
            for pick in picks { self?.openStreamingWindow(for: pick) }
            self?.picker = nil
        }
        p.showWindow(nil)
        p.window?.makeKeyAndOrderFront(nil)
        picker = p
    }

    @discardableResult
    func openStreamingWindow(for descriptor: DeviceDescriptor?) -> MainWindowController {
        picker?.close()
        picker = nil
        let c = MainWindowController(targetDevice: descriptor)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        controller = c                  // most recent — used by menu shortcuts
        controllers.append(c)
        return c
    }

    /// Closing one streaming window doesn't end the session — others may
    /// still be open. Only quit when every window is gone *and* the
    /// picker is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Bring back the picker if the user re-opens the app from the Dock
    /// after closing all windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showPicker() }
        return true
    }

    @objc private func changePassword() {
        controller?.promptForPassword(initial: false)
    }

    @objc private func setQualityLow()    { controller?.applyQuality(.low) }
    @objc private func setQualityMedium() { controller?.applyQuality(.medium) }
    @objc private func setQualityHigh()   { controller?.applyQuality(.high) }

    private func installMenu() {
        let menubar = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Change Password…",
                                   action: #selector(changePassword),
                                   keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())

        let qualityHeader = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        qualityHeader.isEnabled = false
        appMenu.addItem(qualityHeader)
        appMenu.addItem(NSMenuItem(title: "  Low",    action: #selector(setQualityLow),    keyEquivalent: "1"))
        appMenu.addItem(NSMenuItem(title: "  Medium", action: #selector(setQualityMedium), keyEquivalent: "2"))
        appMenu.addItem(NSMenuItem(title: "  High",   action: #selector(setQualityHigh),   keyEquivalent: "3"))
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(title: "Quit",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu

        // Edit menu — required so Cmd-V/Cmd-C work inside NSSecureTextField.
        let editItem = NSMenuItem()
        menubar.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        NSApp.mainMenu = menubar
    }
}
