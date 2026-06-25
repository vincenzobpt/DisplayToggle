import AppKit

// MARK: - Entry Point

// Create and configure the shared application
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon, runs as menu bar app

// Create the delegate manually and assign
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
