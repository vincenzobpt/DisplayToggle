import Foundation
import CoreGraphics
import AppKit

// MARK: - Private SkyLight API

/// Function signature for CGSConfigureDisplayEnabled
/// Takes (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
private typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32

// MARK: - DisplayManager

class DisplayManager {
    
    // MARK: - Constants
    
    static let shared = DisplayManager()
    private let kSavedBuiltinIDKey = "com.displaytoggle.savedBuiltinDisplayID"
    
    // MARK: - Properties
    
    private(set) var isBuiltinDisconnected = false
    /// Persisted display ID: saved to UserDefaults before disabling
    private var savedBuiltinDisplayID: CGDirectDisplayID? {
        get {
            let val = UserDefaults.standard.integer(forKey: kSavedBuiltinIDKey)
            return val > 0 ? CGDirectDisplayID(val) : nil
        }
        set {
            UserDefaults.standard.set(newValue.map(Int.init) ?? 0, forKey: kSavedBuiltinIDKey)
        }
    }
    private var configureFn: ConfigureDisplayEnabledFn? = nil
    private var configureSymbolName: String = ""
    /// Flag to prevent re-entry from display config notifications
    private(set) var isApplyingChange = false
    
    // MARK: - Initialization
    
    private init() {
        detectInitialState()
    }
    
    /// Detect if the built-in display is currently disconnected on startup
    private func detectInitialState() {
        guard let id = findBuiltinDisplayID() else { return }
        // If the display ID is known but not active, it was disconnected before
        let isActive = CGDisplayIsActive(id) != 0
        isBuiltinDisconnected = !isActive
        if isBuiltinDisconnected {
            print("[DisplayToggle] Detected: built-in display is already disconnected (restored state)")
        }
    }
    
    // MARK: - API Loading
    
    /// Load the private SkyLight API symbol
    private func loadAPI() -> Bool {
        if configureFn != nil { return true }
        
        let fwPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        
        var handles: [UnsafeMutableRawPointer?] = []
        if let h = dlopen(fwPath, RTLD_LAZY | RTLD_NOLOAD) { handles.append(h) }
        if let h = dlopen(fwPath, RTLD_LAZY) { handles.append(h) }
        handles.append(dlopen(nil, RTLD_LAZY))
        
        func findSym(_ name: String) -> UnsafeMutableRawPointer? {
            handles.lazy.compactMap { $0.flatMap { dlsym($0, name) } }.first
        }
        
        let candidates = [
            "CGSConfigureDisplayEnabled",
            "CGSSetDisplayEnabled",
            "SLSConfigureDisplayEnabled",
            "SLSSetDisplayEnabled",
        ]
        
        for name in candidates {
            if let sym = findSym(name) {
                configureFn = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
                configureSymbolName = name
                print("[DisplayToggle] Loaded SkyLight API: \(name)")
                return true
            }
        }
        
        print("[DisplayToggle] ERROR: No SkyLight API symbol found (tried: \(candidates))")
        return false
    }
    
    // MARK: - Display Discovery
    
    /// Find the built-in display ID reliably.
    /// Uses CGGetOnlineDisplayList + ID probing (works even for disabled displays)
    func findBuiltinDisplayID() -> CGDirectDisplayID? {
        // Check saved ID first (survives display being removed from online list)
        if let saved = savedBuiltinDisplayID { return saved }
        
        // Method 1: Scan online displays
        var onlineCount: UInt32 = 0
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetOnlineDisplayList(32, &onlineIDs, &onlineCount)
        
        for i in 0..<Int(onlineCount) {
            let id = onlineIDs[i]
            if CGDisplayIsBuiltin(id) != 0 {
                savedBuiltinDisplayID = id
                print("[DisplayToggle] Built-in display found via CGGetOnlineDisplayList: ID \(id)")
                return id
            }
        }
        
        // Method 2: Try CGMainDisplayID
        let mainID = CGMainDisplayID()
        if CGDisplayIsBuiltin(mainID) != 0 {
            savedBuiltinDisplayID = mainID
            print("[DisplayToggle] Built-in display found via CGMainDisplayID: ID \(mainID)")
            return mainID
        }
        
        // Method 3: Probe IDs 1-32 (works even for disabled/disconnected displays)
        for probeID: CGDirectDisplayID in 1...32 {
            if CGDisplayIsBuiltin(probeID) != 0 {
                savedBuiltinDisplayID = probeID
                print("[DisplayToggle] Built-in display found via ID probe: \(probeID)")
                return probeID
            }
        }
        
        // Method 4: NSScreen
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int {
                let cgID = CGDirectDisplayID(id)
                if CGDisplayIsBuiltin(cgID) != 0 {
                    savedBuiltinDisplayID = cgID
                    print("[DisplayToggle] Built-in display found via NSScreen: ID \(cgID)")
                    return cgID
                }
            }
        }
        
        print("[DisplayToggle] ERROR: Built-in display not found!")
        return nil
    }
    
    /// Clear the saved display ID
    func clearSavedDisplayID() {
        savedBuiltinDisplayID = nil
    }
    
    /// Check if there's at least one external display connected
    func hasExternalDisplay() -> Bool {
        var onlineCount: UInt32 = 0
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetOnlineDisplayList(32, &onlineIDs, &onlineCount)
        
        for i in 0..<Int(onlineCount) {
            let id = onlineIDs[i]
            if CGDisplayIsBuiltin(id) == 0 {
                return true
            }
        }
        return false
    }
    
    // MARK: - Display Power Management
    
    /// Apply a display change within a CGBeginDisplayConfiguration / CGCompleteDisplayConfiguration transaction.
    /// Uses `.permanently` which is what mac-display-toggle and Lunar use.
    private func applyDisplayChange(displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard loadAPI(), let fn = configureFn else {
            print("[DisplayToggle] Apply failed: API not loaded")
            return false
        }
        
        isApplyingChange = true
        defer {
            // Small delay to ensure notification handlers see isApplyingChange
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isApplyingChange = false
            }
        }
        
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let config = config else {
            print("[DisplayToggle] CGBeginDisplayConfiguration failed: \(err.rawValue)")
            isApplyingChange = false
            return false
        }
        
        let ret = fn(config, displayID, enabled)
        guard ret == 0 else {
            print("[DisplayToggle] \(configureSymbolName)(enabled: \(enabled)) error: \(ret)")
            CGCancelDisplayConfiguration(config)
            isApplyingChange = false
            return false
        }
        
        err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else {
            print("[DisplayToggle] CGCompleteDisplayConfiguration failed: \(err.rawValue)")
            isApplyingChange = false
            return false
        }
        
        return true
    }
    
    /// Disconnect the built-in display (remove from compositing)
    func disconnectBuiltinDisplay() -> Bool {
        guard loadAPI(), configureFn != nil else {
            print("[DisplayToggle] Disconnect failed: API not loaded")
            return false
        }
        
        guard let displayID = findBuiltinDisplayID() else {
            print("[DisplayToggle] Disconnect failed: built-in display not found")
            return false
        }
        
        guard !isBuiltinDisconnected else {
            print("[DisplayToggle] Display already disconnected, skipping")
            return true
        }
        
        print("[DisplayToggle] Disconnecting display \(displayID) via \(configureSymbolName)...")
        
        // Ensure the display ID is persisted in UserDefaults
        savedBuiltinDisplayID = displayID
        
        let success = applyDisplayChange(displayID: displayID, enabled: false)
        guard success else {
            savedBuiltinDisplayID = nil
            return false
        }
        
        isBuiltinDisconnected = true
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .builtinDisplayStateDidChange, object: nil)
        }
        
        print("[DisplayToggle] Display \(displayID) disconnected successfully")
        return true
    }
    
    /// Reconnect the built-in display (add back to compositing)
    func reconnectBuiltinDisplay() -> Bool {
        guard loadAPI(), configureFn != nil else {
            print("[DisplayToggle] Reconnect failed: API not loaded")
            return false
        }
        
        guard let displayID = findBuiltinDisplayID() else {
            print("[DisplayToggle] Reconnect failed: built-in display not found")
            return false
        }
        
        guard isBuiltinDisconnected else {
            print("[DisplayToggle] Display already connected, skipping")
            return true
        }
        
        print("[DisplayToggle] Reconnecting display \(displayID) via \(configureSymbolName)...")
        
        let success = applyDisplayChange(displayID: displayID, enabled: true)
        guard success else { return false }
        
        isBuiltinDisconnected = false
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .builtinDisplayStateDidChange, object: nil)
        }
        
        print("[DisplayToggle] Display \(displayID) reconnected successfully")
        return true
    }
    
    /// Toggle the built-in display state
    func toggleBuiltinDisplay() -> Bool {
        if isBuiltinDisconnected {
            return reconnectBuiltinDisplay()
        } else {
            return disconnectBuiltinDisplay()
        }
    }
    
    // MARK: - Public Status
    
    /// Check if the built-in display is currently active in WindowServer
    func isBuiltinDisplayActive() -> Bool {
        var onlineCount: UInt32 = 0
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetOnlineDisplayList(32, &onlineIDs, &onlineCount)
        
        guard let builtinID = findBuiltinDisplayID() else { return false }
        
        for i in 0..<Int(onlineCount) {
            if onlineIDs[i] == builtinID {
                var activeCount: UInt32 = 0
                var activeIDs = [CGDirectDisplayID](repeating: 0, count: 32)
                CGGetActiveDisplayList(32, &activeIDs, &activeCount)
                return activeIDs[0..<Int(activeCount)].contains(builtinID)
            }
        }
        return false
    }
    
    /// Get debug info about the display state
    func debugInfo() -> String {
        let builtinID = findBuiltinDisplayID()
        
        var onlineCount: UInt32 = 0
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetOnlineDisplayList(32, &onlineIDs, &onlineCount)
        
        var activeCount: UInt32 = 0
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetActiveDisplayList(32, &activeIDs, &activeCount)
        
        let isAS = isAppleSilicon()
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let apiLoaded = configureFn != nil
        let apiName = configureSymbolName
        
        // Check if builtin display is active directly
        let builtinIsActive = builtinID.map { CGDisplayIsActive($0) != 0 } ?? false
        
        let info = """
        Built-in display ID: \(builtinID ?? 0)
        Built-in active: \(builtinIsActive)
        Apple Silicon: \(isAS)
        macOS: \(osVer)
        API loaded: \(apiLoaded)
        API symbol: \(apiName)
        Disconnected: \(isBuiltinDisconnected)
        Online displays: \(onlineIDs[0..<Int(onlineCount)].map(String.init).joined(separator: ", "))
        Active displays: \(activeIDs[0..<Int(activeCount)].map(String.init).joined(separator: ", "))
        External display: \(hasExternalDisplay())
        """
        
        return info
    }
}

// MARK: - Notification

extension Notification.Name {
    static let builtinDisplayStateDidChange = Notification.Name("builtinDisplayStateDidChange")
}

// MARK: - Platform Detection

func isAppleSilicon() -> Bool {
    var cputype: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    let ret = sysctlbyname("hw.cputype", &cputype, &size, nil, 0)
    guard ret == 0 else { return false }
    let CPU_TYPE_ARM64: UInt32 = 16777228
    return cputype == CPU_TYPE_ARM64
}
