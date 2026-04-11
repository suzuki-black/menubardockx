import AppKit

// Explicit entry point — more reliable than @NSApplicationMain on newer macOS.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
