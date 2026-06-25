import Cocoa
import IOKit
import UserNotifications

// MARK: - Application Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Constants

    private let kAutoBlackoutKey = "com.displaytoggle.autoBlackout"
    private let kDisconnectedStateKey = "com.displaytoggle.disconnectedState"

    // MARK: - UI

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var autoBlackoutMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var displayLinkWarningMenuItem: NSMenuItem!
    private var accessibilityMenuItem: NSMenuItem!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for display configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Listen for state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuItems),
            name: .builtinDisplayStateDidChange,
            object: nil
        )

        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        setupMenuBar()
        setupHotkey()

        // Restore previous state
        restoreState()

        // Show DisplayLink warning if needed
        checkDisplayLink()

        print("[DisplayToggle] App started. Apple Silicon: \(isAppleSilicon())")
        if let id = DisplayManager.shared.findBuiltinDisplayID() {
            print("[DisplayToggle] Built-in display ID: \(id)")
        } else {
            print("[DisplayToggle] Built-in display not found")
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.title = "🌙"
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu = NSMenu()
        menu.delegate = self

        // Status info item
        statusMenuItem = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle item
        toggleMenuItem = NSMenuItem(
            title: "Disconnect Built-in Display",
            action: #selector(toggleBlackOut),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Auto BlackOut toggle
        autoBlackoutMenuItem = NSMenuItem(
            title: "Auto BlackOut: OFF",
            action: #selector(toggleAutoBlackout),
            keyEquivalent: ""
        )
        autoBlackoutMenuItem.target = self
        menu.addItem(autoBlackoutMenuItem)

        menu.addItem(NSMenuItem.separator())

        // DisplayLink warning
        displayLinkWarningMenuItem = NSMenuItem(
            title: "", action: nil, keyEquivalent: ""
        )
        displayLinkWarningMenuItem.isEnabled = false
        displayLinkWarningMenuItem.isHidden = true
        menu.addItem(displayLinkWarningMenuItem)

        // Accessibility status
        accessibilityMenuItem = NSMenuItem(
            title: "", action: #selector(openAccessibilitySettings), keyEquivalent: ""
        )
        accessibilityMenuItem.target = self
        accessibilityMenuItem.isHidden = true
        menu.addItem(accessibilityMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Debug info
        let debugItem = NSMenuItem(title: "Show Debug Info", action: #selector(showDebugInfo), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit DisplayToggle", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuItems()
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        // Setup hotkey handler — toggles display on Cmd+Alt+Shift+1
        HotkeyManager.shared.onEmergencyReconnect = { [weak self] in
            self?.performEmergencyToggle()
        }

        // Try to register the hotkey
        HotkeyManager.shared.startMonitoring()

        // If registration failed (no accessibility), show guidance
        if !HotkeyManager.shared.isRegistered {
            print("[DisplayToggle] Hotkey registration failed. Accessibility permissions needed.")
            print("[DisplayToggle] To enable: System Settings → Privacy & Security → Accessibility → add DisplayToggle")
            accessibilityMenuItem.title = "⚠️ Enable Accessibility for Cmd+Alt+Shift+1"
            accessibilityMenuItem.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func toggleBlackOut() {
        let dm = DisplayManager.shared
        if dm.isBuiltinDisconnected {
            reconnect()
        } else {
            disconnect()
        }
    }

    private func disconnect() {
        let dm = DisplayManager.shared

        guard dm.findBuiltinDisplayID() != nil else {
            showAlert(
                title: "No Built-in Display Found",
                message: "Could not detect a built-in display. Make sure you're running on a MacBook."
            )
            return
        }

        // Warn if DisplayLink is active
        if isDisplayLinkActive() {
            let alert = NSAlert()
            alert.messageText = "DisplayLink Detected"
            alert.informativeText = """
            DisplayLink drivers are active. Disconnecting the built-in display may cause \
            instability, screen flicker, or crashes. Proceed with caution.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Disconnect Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Ensure external display is connected
        guard dm.hasExternalDisplay() else {
            showAlert(
                title: "No External Display",
                message: "You need at least one external display connected to disconnect the built-in display."
            )
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let success = dm.disconnectBuiltinDisplay()
            DispatchQueue.main.async {
                if success {
                    self.showNotification(title: "Display Disconnected", body: "Built-in display turned off")
                } else {
                    self.showAlert(
                        title: "Disconnect Failed",
                        message: "Could not disconnect the built-in display. The API may have changed in this macOS version."
                    )
                }
            }
        }
    }

    private func reconnect() {
        let dm = DisplayManager.shared

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let success = dm.reconnectBuiltinDisplay()
            DispatchQueue.main.async {
                if success {
                    self.showNotification(title: "Display Reconnected", body: "Built-in display turned on")
                } else {
                    self.showAlert(
                        title: "Reconnect Failed",
                        message: """
                        Could not reconnect the built-in display. Try:
                        • Close and reopen the MacBook lid
                        • Restart your Mac
                        • Press Cmd+Alt+Shift+1 again (requires Accessibility permission)
                        """
                    )
                }
            }
        }
    }

    @objc private func toggleAutoBlackout() {
        let current = UserDefaults.standard.bool(forKey: kAutoBlackoutKey)
        UserDefaults.standard.set(!current, forKey: kAutoBlackoutKey)
        updateMenuItems()
        print("[DisplayToggle] Auto BlackOut: \(current ? "OFF" : "ON")")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Display Configuration Changes (Auto BlackOut)

    @objc private func displayConfigurationChanged() {
        // Don't act if we're the one applying the change
        guard !DisplayManager.shared.isApplyingChange else { return }

        let autoBlackout = UserDefaults.standard.bool(forKey: kAutoBlackoutKey)
        guard autoBlackout else { return }

        let dm = DisplayManager.shared
        let maxDisplays: UInt32 = 32
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        CGGetActiveDisplayList(maxDisplays, &displays, &displayCount)

        let externalCount = (0 ..< Int(displayCount)).filter {
            CGDisplayIsBuiltin(displays[$0]) == 0
        }.count

        if externalCount > 0 && !dm.isBuiltinDisconnected {
            print("[DisplayToggle] Auto BlackOut: External display detected, disconnecting built-in")
            disconnect()
        } else if externalCount == 0 && dm.isBuiltinDisconnected {
            print("[DisplayToggle] Auto BlackOut: No external displays, reconnecting built-in")
            reconnect()
        }
    }

    // MARK: - Hotkey Action

    @objc private func performEmergencyToggle() {
        let dm = DisplayManager.shared
        print("[DisplayToggle] Hotkey: toggling built-in display")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let wasDisconnected = dm.isBuiltinDisconnected
            let success = dm.toggleBuiltinDisplay()
            DispatchQueue.main.async {
                if success {
                    self.showNotification(
                        title: wasDisconnected ? "Display Reconnected" : "Display Disconnected",
                        body: wasDisconnected ? "Built-in display turned on" : "Built-in display turned off"
                    )
                } else {
                    self.showAlert(
                        title: "Toggle Failed",
                        message: "Could not toggle the built-in display state."
                    )
                }
            }
        }
    }

    // MARK: - DisplayLink Warning

    private func checkDisplayLink() {
        if isDisplayLinkActive() {
            displayLinkWarningMenuItem.title = "⚠️ DisplayLink Active — may conflict"
            displayLinkWarningMenuItem.isHidden = false
        }
    }

    /// Check if DisplayLink or other kernel display drivers are loaded
    private func isDisplayLinkActive() -> Bool {
        let matching = IOServiceMatching("DisplayLinkFramebuffer")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return false }

        let hasService = IOIteratorNext(iterator) != 0
        IOObjectRelease(iterator)
        return hasService
    }

    // MARK: - State Persistence

    private func restoreState() {
        let wasDisconnected = UserDefaults.standard.bool(forKey: kDisconnectedStateKey)
        _ = UserDefaults.standard.bool(forKey: kAutoBlackoutKey)

        if wasDisconnected {
            print("[DisplayToggle] Restoring previous state: display was disconnected")
        }

        updateMenuItems()
    }

    private func saveState() {
        UserDefaults.standard.set(
            DisplayManager.shared.isBuiltinDisconnected,
            forKey: kDisconnectedStateKey
        )
    }

    // MARK: - UI Updates

    @objc private func updateMenuItems() {
        let dm = DisplayManager.shared

        statusMenuItem.title = "Built-in: \(dm.isBuiltinDisconnected ? "OFF" : "ON")"

        if dm.isBuiltinDisconnected {
            toggleMenuItem.title = "Reconnect Built-in Display"
        } else {
            toggleMenuItem.title = "Disconnect Built-in Display"
        }

        let autoOn = UserDefaults.standard.bool(forKey: kAutoBlackoutKey)
        autoBlackoutMenuItem.title = "Auto BlackOut: \(autoOn ? "ON" : "OFF")"
        autoBlackoutMenuItem.state = autoOn ? .on : .off

        saveState()
    }

    // MARK: - Debug

    @objc private func showDebugInfo() {
        let info = DisplayManager.shared.debugInfo()
        let alert = NSAlert()
        alert.messageText = "DisplayToggle Debug Info"
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItems()
        checkDisplayLink()

        // Re-check hotkey: if registered but still showing warning, hide it
        if HotkeyManager.shared.isRegistered {
            accessibilityMenuItem.isHidden = true
        }
        // If not registered, try registering again (user may have just granted permissions)
        if !HotkeyManager.shared.isRegistered {
            HotkeyManager.shared.startMonitoring()
            if HotkeyManager.shared.isRegistered {
                accessibilityMenuItem.isHidden = true
                print("[DisplayToggle] Hotkey now registered (accessibility was granted)")
            }
        }
    }
}
