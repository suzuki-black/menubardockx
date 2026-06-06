import AppKit
import ObjectiveC
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    #if DEBUG
    private static let debugLog = FileHandle(forWritingAtPath: {
        let path = "/tmp/mbdx_debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }())

    private func dbg(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        Self.debugLog?.write(line.data(using: .utf8)!)
    }
    #else
    private func dbg(_ msg: String) {}
    #endif

    private var statusItem: NSStatusItem?
    /// overflow でない通常時のアイコン（復元用）
    private var normalStatusIcon: NSImage?

    // Shared enumerator (used by the overflow manager)
    private let sharedEnumerator = MenuBarEnumerator()

    private var languageObserver: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // We live in the menu bar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory ポリシーで起動することで Dock アイコンを非表示にする。
        NSApp.setActivationPolicy(.accessory)

        // Terminate duplicate instances (can happen during development)
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.menubar.MenuBarDockX")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
        dbg("applicationDidFinishLaunching")

        // ログイン時自動起動を初回起動時にオファーする
        promptLoginItemIfNeeded()

        // Environment check
        let report = EnvironmentChecker.run()
        dbg("AX=\(report.hasAccessibility) version=\(report.versionSupport) rosetta=\(report.rosettaStatus)")
        EnvironmentChecker.requestAccessibilityIfNeeded()
        dbg("after requestAX: AX=\(AXIsProcessTrusted())")

        // NSStatusItem を作成し、overflow 検出コールバックを登録してから polling 開始
        setupStatusItem()

        // Overflow 検出開始
        if let si = statusItem {
            OverflowStatusManager.shared.start(with: sharedEnumerator, statusItem: si)
        }

        // グローバルショートカット起動（⌥⌘M でパネルを開く）
        // アイコンが dead zone に押し出されても常に動作する。
        GlobalShortcutManager.shared.start()

        // Show environment warnings (non-blocking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            EnvironmentChecker.presentReport(report, in: nil)
        }

        // Rebuild menu when language changes
        languageObserver = NotificationCenter.default.addObserver(
            forName: LanguageManager.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        dbg("setupStatusItem")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // アイコン候補（OS バージョンによって使えるシンボルが異なる）
        let symbolNames = ["menubar.rectangle", "menubar.dock.rectangle",
                           "rectangle.3.group", "square.grid.2x2.fill"]
        var resolvedIcon: NSImage?
        for name in symbolNames {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "MenuBarDockX") {
                resolvedIcon = img
                dbg("icon resolved: \(name)")
                break
            }
        }

        if let icon = resolvedIcon {
            icon.isTemplate = true
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let configured = icon.withSymbolConfiguration(cfg)
            statusItem?.button?.image = configured
            normalStatusIcon = configured      // 復元用に保存
        } else {
            statusItem?.button?.title = "⬟"
            statusItem?.button?.font  = .boldSystemFont(ofSize: 13)
        }

        statusItem?.button?.toolTip = "MenuBarDockX"
        statusItem?.menu = makeMenu()
        dbg("setupStatusItem done isVisible=\(statusItem?.isVisible == true)")

        // overflow ON/OFF に応じてアイコンとメニューを切り替える
        OverflowStatusManager.shared.onOverflowModeChanged = { [weak self] isOverflow in
            self?.updateForOverflowMode(isOverflow)
        }
    }

    /// overflow 状態の変化に応じてアイコンとクリック動作を更新する。
    /// メインスレッドから呼ばれる前提。
    private func updateForOverflowMode(_ isOverflow: Bool) {
        if isOverflow {
            // ▾（下向き三角）に変更
            if let img = NSImage(systemSymbolName: "arrowtriangle.down.fill",
                                 accessibilityDescription: "Show hidden menu bar items") {
                img.isTemplate = true
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                statusItem?.button?.image = img.withSymbolConfiguration(cfg)
            }
            // overflow 中はメニューを外し、1クリックで直接パネルを開く
            statusItem?.menu = nil
            statusItem?.button?.action = #selector(showHiddenItems)
            statusItem?.button?.target = self
            statusItem?.button?.toolTip = L("Show hidden menu bar items",
                                            "隠れたメニューバーアイテムを表示")
        } else {
            // 通常アイコンに戻してメニューを復元
            statusItem?.button?.image = normalStatusIcon
            statusItem?.button?.action = nil
            statusItem?.button?.target = nil
            statusItem?.menu = makeMenu()
            statusItem?.button?.toolTip = "MenuBarDockX"
        }
        dbg("updateForOverflowMode isOverflow=\(isOverflow)")
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: L("About MenuBarDockX…", "このアプリについて…"),
                     action: #selector(showAbout),
                     keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())

        // ログイン時自動起動トグル（タイトル固定・チェックマークで状態を示す）
        let loginItem = menu.addItem(
            withTitle: L("Launch at Login", "ログイン時に自動起動"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItemManager.shared.isEnabled ? .on : .off

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L("Quit MenuBarDockX", "MenuBarDockX を終了"),
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        #if DEBUG
        DebugMenuManager.shared.addDebugSection(to: menu)
        #endif

        return menu
    }

    private func rebuildMenu() {
        statusItem?.menu = makeMenu()
    }

    // MARK: - Login Item prompt

    private static let loginItemPromptedKey = "loginItemPromptShown"

    /// 初回起動時（ログイン項目未登録時）に自動起動をオファーするダイアログを表示する。
    ///
    /// macOS 26 Tahoe ではメニューバーの右ゾーンが満杯の場合、後から起動したアプリは
    /// ノッチ左の dead zone に押し出され ▾ インジケーターが見えなくなる。
    /// ログイン項目として最も早く起動することでスロットを確保できる。
    private func promptLoginItemIfNeeded() {
        guard !LoginItemManager.shared.isEnabled else { return }
        guard !UserDefaults.standard.bool(forKey: Self.loginItemPromptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.loginItemPromptedKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = L(
                "Launch MenuBarDockX at Login?",
                "ログイン時に MenuBarDockX を自動起動しますか？")
            alert.informativeText = L(
                """
                On macOS Sequoia / Tahoe, the ▾ indicator is only visible if \
                MenuBarDockX starts before other menu bar apps.

                Enabling "Launch at Login" lets it start first and grab a slot \
                in the visible zone.

                You can change this later from the MenuBarDockX menu.
                """,
                """
                macOS Sequoia / Tahoe では、MenuBarDockX が他のメニューバーアプリより \
                先に起動した場合のみ ▾ インジケーターが表示されます。

                「ログイン時に自動起動」を有効にすると起動順を最優先にできます。

                この設定は後から MenuBarDockX メニューで変更できます。
                """)
            alert.alertStyle = .informational
            if let icon = NSApp.applicationIconImage { alert.icon = icon }
            alert.addButton(withTitle: L("Enable", "有効にする"))
            alert.addButton(withTitle: L("Not Now", "あとで"))

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                LoginItemManager.shared.enable()
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Actions

    @objc private func showHiddenItems() {
        OverflowStatusManager.shared.togglePanel()
    }

    @objc private func toggleLaunchAtLogin() {
        if LoginItemManager.shared.isEnabled {
            LoginItemManager.shared.disable()
        } else {
            LoginItemManager.shared.enable()
        }
        rebuildMenu()
    }

    @objc func showAboutFromMenu() { showAbout() }

    @objc private func showAbout() {
        let info    = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build   = info["CFBundleVersion"]            as? String ?? "–"

        let alert = NSAlert()
        alert.messageText     = "MenuBarDockX"
        alert.informativeText = """
            \(L("Version", "バージョン")) \(version) (build \(build))

            \(L("Bring your hidden menu bar icons back into view.",
                "macOS のメニューバーを、見える場所に取り戻す。"))

            \(L("Shortcut: ⌃⌥⌘M opens the overflow panel.",
                "ショートカット: ⌃⌥⌘M でオーバーフローパネルを開きます。"))

            © 2026 suzuki-black
            MIT License
            """
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        alert.addButton(withTitle: L("Close", "閉じる"))
        alert.runModal()
    }
}
