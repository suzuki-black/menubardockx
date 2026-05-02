import AppKit
import ObjectiveC

// MARK: - NSStatusBar private API ──────────────────────────────────────────────
// _statusItemWithLength:withPriority: は非公開 Obj-C メソッド。
// 優先度を指定することで status item の配置位置を制御できる。
// 優先度が高い(大きい)ほど、より右側(ノッチから遠く安定した位置)に配置される。
//
// 既知の優先度レンジ:
//   0        : デフォルト三者製 (最左寄り、不安定)
//   ~INT32_MAX: システム項目 (最右端、固定)
//   1000     : 三者製最右端付近 (本実装で使用)
//
// iOS/macOS App Store 提出を前提としないOSSのため private API 使用を許容する。
// フォールバック: API が存在しない場合は公開 API で通常作成。
private extension NSStatusBar {
    typealias _StatusItemFn = @convention(c) (NSStatusBar, Selector, CGFloat, Int) -> NSStatusItem

    /// 優先度付きで NSStatusItem を作成する (private API ラッパー)。
    func statusItem(withLength length: CGFloat, priority: Int) -> NSStatusItem {
        let sel = NSSelectorFromString("_statusItemWithLength:withPriority:")
        guard responds(to: sel),
              let method = class_getInstanceMethod(type(of: self), sel) else {
            return self.statusItem(withLength: length)  // fallback
        }
        let imp = method_getImplementation(method)
        let fn  = unsafeBitCast(imp, to: _StatusItemFn.self)
        return fn(self, sel, length, priority)
    }
}

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

    private var statusItem: NSStatusItem?

    // Shared enumerator (used by the overflow manager)
    private let sharedEnumerator = MenuBarEnumerator()

    private var languageObserver: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // We live in the menu bar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory / .prohibited ポリシーのままだと NSApp.keyWindow が常に nil になり、
        // OverflowPanel を makeKeyAndOrderFront しても keyWindow になれない。
        // .regular に昇格することで keyWindow の取得が可能になる。
        // ※ Dock アイコンが表示されるが、パネルが青くなる・歯車が 1 クリックで押せる
        //   ことへの代償として許容する。
        NSApp.setActivationPolicy(.regular)

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

        // App's own menu bar status item
        setupStatusItem()

        // Notch overflow UI — statusItem を渡して overflow 時にボタンを切り替える
        if let si = statusItem {
            OverflowStatusManager.shared.start(with: sharedEnumerator, statusItem: si)
        }

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
        // 優先度 1000 で作成 → システムアイテムより左、一般三者製より右の安定位置に配置される。
        // これにより他のアプリがアイテムを追加してもアイコンがノッチ内に押し込まれにくくなる。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength, priority: 1000)

        // macOS 26 (Tahoe) では透明メニューバーのため menubar.rectangle が不可視になる場合がある。
        // 複数シンボルを試してフォールバックし、最終的にテキストで確実に表示する。
        let symbolNames = ["menubar.rectangle", "menubar.dock.rectangle",
                           "rectangle.3.group", "square.grid.2x2.fill"]
        var resolvedIcon: NSImage?
        for name in symbolNames {
            if let img = NSImage(systemSymbolName: name,
                                 accessibilityDescription: "MenuBarDockX") {
                resolvedIcon = img
                dbg("icon resolved: \(name)")
                break
            }
        }

        if let icon = resolvedIcon {
            // isTemplate=true にして Dark/Light 両対応。
            icon.isTemplate = true
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            statusItem?.button?.image = icon.withSymbolConfiguration(cfg)
            dbg("icon=set image button=\(String(describing: statusItem?.button))")
        } else {
            // 完全フォールバック: SF Symbol が使えない場合はテキストで表示
            statusItem?.button?.title = "⬟"
            statusItem?.button?.font = .boldSystemFont(ofSize: 13)
            dbg("icon=FALLBACK text button=\(String(describing: statusItem?.button))")
        }

        statusItem?.button?.toolTip = "MenuBarDockX"
        dbg("status item visible=\(statusItem?.isVisible == true)")

        statusItem?.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("About MenuBarDockX…", "このアプリについて…"),
                     action: #selector(showAbout),
                     keyEquivalent: "")
            .target = self
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

    // MARK: - Actions

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
