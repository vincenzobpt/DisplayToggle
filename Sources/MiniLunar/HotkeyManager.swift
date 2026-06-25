import Cocoa
import Carbon

// MARK: - Global Hotkey Manager

/// Handles the global hotkey Cmd+Alt+Shift+1 for emergency display reconnect.
/// Uses Carbon RegisterEventHotKey API (requires Accessibility permissions).
class HotkeyManager {
    static let shared = HotkeyManager()

    /// Called when the emergency hotkey is pressed
    var onEmergencyReconnect: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyId: EventHotKeyID
    private(set) var isRegistered = false

    private init() {
        hotKeyId = EventHotKeyID(signature: 0x4D4C524E, id: 1) // "MLRN" = MiniLunar
    }

    deinit {
        unregisterHotKey()
    }

    // MARK: - Registration

    /// Register the emergency hotkey Cmd+Alt+Shift+1
    func startMonitoring() {
        guard !isRegistered else { return }
        
        // Key code for '1' (kVK_ANSI_1 = 18)
        let keyCode: UInt32 = 18
        let modifiers = UInt32(cmdKey | optionKey | shiftKey)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            isRegistered = true
            installEventHandler()
            print("[MiniLunar] Emergency hotkey Cmd+Alt+Shift+1 registered")
        } else {
            print("[MiniLunar] Failed to register hotkey (error \(status))")
        }
    }

    func stopMonitoring() {
        unregisterHotKey()
    }

    private func unregisterHotKey() {
        guard isRegistered, let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
        isRegistered = false
        print("[MiniLunar] Hotkey unregistered")
    }

    // MARK: - Event Handler

    private var eventHandlerInstalled = false

    private func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyHandlerCallback,
            1,
            &eventSpec,
            nil,
            nil
        )
    }

    // MARK: - Permissions

    /// Check if the app has Accessibility permissions
    static func hasAccessibilityPermissions() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Prompt user to grant Accessibility permissions
    static func requestAccessibilityPermissions() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        MiniLunar needs Accessibility access to monitor the global hotkey \
        Cmd+Alt+Shift+1 for emergency display reconnection.

        Please go to System Settings → Privacy & Security → Accessibility \
        and add MiniLunar to the list.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Global C callback for Carbon hotkey events
private func hotkeyHandlerCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        OSType(kEventParamDirectObject),
        OSType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )

    if status == noErr, hotkeyID.signature == 0x4D4C524E, hotkeyID.id == 1 {
        DispatchQueue.main.async {
            HotkeyManager.shared.onEmergencyReconnect?()
        }
        return noErr
    }

    return OSStatus(eventNotHandledErr)
}
