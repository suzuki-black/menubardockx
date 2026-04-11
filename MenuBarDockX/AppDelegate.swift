import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let debugLog = FileHandle(forWritingAtPath: {
        let path = "/tmp/mbdx_debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }())

    private func dbg(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        Self.debugLog?.write(line.data(using: .utf8)!)
    }

    private var launcherController: LauncherWindowController?
    private var statusItem: NSStatusItem?

    // Shared enumerator (used by both launcher and overflow manager)
    private let sharedEnumerator = MenuBarEnumerator()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        launcherController?.showPanel()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate duplicate instances (can happen during development)
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.menubar.MenuBarDockX")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
        dbg("applicationDidFinishLaunching")
        // Environment check
        let report = EnvironmentChecker.run()
        dbg("AX=\(report.hasAccessibility) version=\(report.versionSupport) rosetta=\(report.rosettaStatus)")
        EnvironmentChecker.requestAccessibilityIfNeeded()
        dbg("after requestAX: AX=\(AXIsProcessTrusted())")

        // Build the launcher window
        launcherController = LauncherWindowController(enumerator: sharedEnumerator)

        // App's own menu bar status item
        setupStatusItem()

        // Global shortcut (⌥⌘M)
        let shortcutSpec = DataStore.shared.shortcut
        GlobalShortcutManager.shared.register(keyCode: shortcutSpec.keyCode,
                                               modifiers: shortcutSpec.modifiers)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(globalShortcutFired),
            name: .globalShortcutTriggered,
            object: nil
        )

        // Pre-enumerate in background so launcher is populated on first open
        launcherController?.preloadItems()

        // Notch overflow UI (no-op on screens without a notch)
        OverflowStatusManager.shared.start(with: sharedEnumerator)

        // Show environment warnings (non-blocking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            EnvironmentChecker.presentReport(report, in: self?.launcherController?.window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // We live in the menu bar
    }

    // MARK: - Status item

    private func setupStatusItem() {
        dbg("setupStatusItem")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "MenuBarDockX")
        dbg("icon=\(String(describing: icon)) button=\(String(describing: statusItem?.button))")
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "MenuBarDockX"
        dbg("status item visible=\(statusItem?.isVisible == true)")

        let menu = NSMenu()
        menu.addItem(withTitle: "ランチャーを開く / 閉じる",
                     action: #selector(toggleLauncher),
                     keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "アクセシビリティ権限を確認",
                     action: #selector(checkPermissions),
                     keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "MenuBarDockX を終了",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        #if DEBUG
        DebugMenuManager.shared.addDebugSection(to: menu)
        #endif

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleLauncher() {
        launcherController?.toggle()
    }

    @objc private func globalShortcutFired() {
        launcherController?.toggle()
    }

    @objc private func checkPermissions() {
        EnvironmentChecker.requestAccessibilityIfNeeded()
        let report = EnvironmentChecker.run()
        EnvironmentChecker.presentReport(report, in: launcherController?.window)
    }
}
