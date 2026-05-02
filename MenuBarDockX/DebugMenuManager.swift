#if DEBUG
import AppKit

// MARK: - DebugSettings ───────────────────────────────────────────────────────

final class DebugSettings {
    static let shared = DebugSettings()
    private init() {}

    var simulatedNotchEnabled: Bool = false {
        didSet { NotificationCenter.default.post(name: .debugSettingsChanged, object: nil) }
    }
    var dummyIconsEnabled: Bool = false {
        didSet { NotificationCenter.default.post(name: .debugSettingsChanged, object: nil) }
    }

    // MARK: Dummy icon count
    // Number of dummy NSStatusItems to add when "ダミーアイコンでバーを埋める" is ON.
    // Selectable via the debug submenu so we can test guillemet position with
    // different amounts of overflow (1 item → just barely overflows, 20 → many hidden).
    private static let dummyCountKey = "debug.dummyIconCount"
    var dummyIconCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.dummyCountKey)
            return v > 0 ? v : 5   // default 5
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.dummyCountKey) }
    }

    // MARK: JetBrains Toolbox pinned item (left/right click verification)

    /// When true, Toolbox is always prepended to the overflow panel regardless of its
    /// menu-bar position. Use this to verify left vs. right click proxy behaviour.
    var pinnedToolboxEnabled: Bool = false {
        didSet { OverflowStatusManager.shared.forceRefresh() }
    }

    /// Width of the simulated notch (pt, centered on main screen).
    static let simulatedNotchWidth: CGFloat = 200

    /// Returns simulated NotchInfo when active.
    func makeSimulatedNotchInfo() -> NotchInfo? {
        guard simulatedNotchEnabled, let screen = NSScreen.main else { return nil }
        let cx = screen.frame.midX
        let hw = Self.simulatedNotchWidth / 2
        return NotchInfo(hasNotch: true, leftEdgeX: cx - hw, rightEdgeX: cx + hw)
    }

    /// Actual hidden dummy items — set by DebugMenuManager after position detection.
    var hiddenDummyItems: [MenuBarItem] = []

    /// Called by OverflowStatusManager to supplement real hidden items.
    func makeDummyHiddenItems() -> [MenuBarItem] { hiddenDummyItems }

    /// If Toolbox pinning is enabled, prepends the Toolbox MenuBarItem to `items`.
    /// Runs on the background thread (same as poll).
    func prependPinnedItems(to items: inout [MenuBarItem], using enumerator: MenuBarEnumerator) {
        guard pinnedToolboxEnabled else { return }
        // Remove existing Toolbox entry to avoid duplicates
        items.removeAll { $0.bundleID == "com.jetbrains.toolbox" }
        if let toolbox = enumerator.findToolboxItem() {
            items.insert(toolbox, at: 0)
            NSLog("[DEBUG][Toolbox] pinned item prepended to overflow panel (count=%d)", items.count)
        } else {
            NSLog("[DEBUG][Toolbox] pinned enabled but Toolbox not found in menu bar")
        }
    }
}

extension Notification.Name {
    static let debugSettingsChanged = Notification.Name("com.menubar.MenuBarDockX.debugSettingsChanged")
}

// MARK: - DebugMenuManager ────────────────────────────────────────────────────

final class DebugMenuManager {
    static let shared = DebugMenuManager()
    private init() {}

    private weak var notchMenuItem:   NSMenuItem?
    private weak var dummyMenuItem:   NSMenuItem?
    private weak var toolboxMenuItem: NSMenuItem?
    // Key: count value, Value: menu item (for checkmark management)
    private var countMenuItems: [Int: NSMenuItem] = [:]

    private var overlayWindow: SimulatedNotchOverlay?

    // Each dummy entry holds both the NSStatusItem (for showing/hiding in bar)
    // and a MenuBarItem (for displaying in the overflow panel).
    private struct DummyEntry {
        let statusItem: NSStatusItem
        var menuBarItem: MenuBarItem
    }
    private var dummyEntries: [DummyEntry] = []

    // MARK: Menu setup

    func addDebugSection(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let header = NSMenuItem(title: "— DEBUG —", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "— DEBUG —",
            attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.boldSystemFont(ofSize: 11),
            ]
        )
        menu.addItem(header)

        let notchItem = NSMenuItem(title: "擬似ノッチ (Simulate Notch)",
                                   action: #selector(toggleSimulatedNotch),
                                   keyEquivalent: "")
        notchItem.target = self
        notchItem.state  = .off
        menu.addItem(notchItem)
        notchMenuItem = notchItem

        let dummyItem = NSMenuItem(title: "ダミーアイコンでバーを埋める",
                                   action: #selector(toggleDummyIcons),
                                   keyEquivalent: "")
        dummyItem.target = self
        dummyItem.state  = .off
        menu.addItem(dummyItem)
        dummyMenuItem = dummyItem

        let toolboxItem = NSMenuItem(title: "JetBrains Toolbox を常に表示 (左右クリック検証)",
                                     action: #selector(togglePinnedToolbox),
                                     keyEquivalent: "")
        toolboxItem.target = self
        toolboxItem.state  = .off
        menu.addItem(toolboxItem)
        toolboxMenuItem = toolboxItem

        // Dummy icon count submenu
        let countSubMenu = NSMenu()
        let countParent  = NSMenuItem(title: "ダミーアイコン数: \(DebugSettings.shared.dummyIconCount)個",
                                      action: nil, keyEquivalent: "")
        menu.addItem(countParent)
        menu.setSubmenu(countSubMenu, for: countParent)

        countMenuItems.removeAll()
        let counts = [1, 2, 3, 5, 8, 10, 15, 20]
        let current = DebugSettings.shared.dummyIconCount
        for n in counts {
            let item = NSMenuItem(title: "\(n)個",
                                  action: #selector(selectDummyCount(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag    = n
            item.state  = (n == current) ? .on : .off
            countSubMenu.addItem(item)
            countMenuItems[n] = item
        }

        let axItem = NSMenuItem(title: "アクセシビリティ権限を確認",
                                action: #selector(checkPermissions),
                                keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
    }

    @objc private func checkPermissions() {
        EnvironmentChecker.requestAccessibilityIfNeeded()
        let report = EnvironmentChecker.run()
        EnvironmentChecker.presentReport(report, in: nil)
    }

    // MARK: Toggle actions

    @objc private func toggleSimulatedNotch() {
        let s = DebugSettings.shared
        s.simulatedNotchEnabled.toggle()
        notchMenuItem?.state = s.simulatedNotchEnabled ? .on : .off

        if s.simulatedNotchEnabled {
            showNotchOverlay()
            // Re-apply hiding to existing dummy items
            if !dummyEntries.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.applyNotchHiding()
                }
            } else {
                OverflowStatusManager.shared.forceRefresh()
            }
        } else {
            // Tear down simulated notch
            overlayWindow?.orderOut(nil)
            overlayWindow = nil
            // Restore all dummy items to visible
            dummyEntries.forEach { $0.statusItem.isVisible = true }
            DebugSettings.shared.hiddenDummyItems = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OverflowStatusManager.shared.displayItems([])
            }
        }
    }

    @objc private func togglePinnedToolbox() {
        let s = DebugSettings.shared
        s.pinnedToolboxEnabled.toggle()
        toolboxMenuItem?.state = s.pinnedToolboxEnabled ? .on : .off
        NSLog("[DEBUG][Toolbox] pinned=%@", s.pinnedToolboxEnabled ? "ON" : "OFF")
    }

    @objc private func selectDummyCount(_ sender: NSMenuItem) {
        let n = sender.tag
        DebugSettings.shared.dummyIconCount = n
        // Update checkmarks
        countMenuItems.forEach { $0.value.state = ($0.key == n) ? .on : .off }
        // Update parent title (best-effort)
        if let subMenu = sender.menu, let parent = subMenu.supermenu {
            if let idx = parent.items.firstIndex(where: { $0.submenu === subMenu }) {
                parent.items[idx].title = "ダミーアイコン数: \(n)個"
            }
        }
        // If dummy icons are currently active, re-apply with new count
        if DebugSettings.shared.dummyIconsEnabled {
            removeDummyIcons()
            addDummyIcons()
        }
    }

    @objc private func toggleDummyIcons() {
        let s = DebugSettings.shared
        s.dummyIconsEnabled.toggle()
        dummyMenuItem?.state = s.dummyIconsEnabled ? .on : .off

        if s.dummyIconsEnabled {
            addDummyIcons()
        } else {
            removeDummyIcons()
        }
    }

    // MARK: Simulated notch overlay

    private func showNotchOverlay() {
        guard let screen = NSScreen.main else { return }
        let overlay = SimulatedNotchOverlay(screen: screen)
        overlay.orderFront(nil)
        overlayWindow = overlay
    }

    // MARK: Dummy icons

    private func addDummyIcons() {
        removeDummyIcons()

        // Use the user-selected count. Width is fixed to squareLength so each item
        // takes the same space regardless of notch type, making count intuitive.
        let itemCount = DebugSettings.shared.dummyIconCount
        let itemWidth: CGFloat = NSStatusItem.squareLength

        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                  .systemGreen, .systemBlue, .systemPurple]

        for i in 0..<itemCount {
            let idx   = i + 1
            let color = colors[i % colors.count]
            let image = makeDummyImage(index: idx, color: color)
            let label = String(format: "%02d", idx)

            // NSStatusItem for the menu bar
            let statusItem = NSStatusBar.system.statusItem(withLength: itemWidth)
            if let btn = statusItem.button {
                btn.image         = image
                btn.imagePosition = .imageLeft
                btn.attributedTitle = NSAttributedString(
                    string: " \(label)",
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    ]
                )
                btn.toolTip = "DEBUG \(label)"
            }

            // MenuBarItem for the overflow panel
            var mbItem = MenuBarItem(
                id: UUID(),
                bundleID: "com.debug.dummy.\(i)",
                appName: "TEST \(label)",
                axDescription: "TEST \(label)",
                frame: .zero,
                isSystemItem: false,
                categoryID: nil,
                sortOrder: i
            )
            mbItem.isHidden = true
            mbItem.image    = image

            dummyEntries.append(DummyEntry(statusItem: statusItem, menuBarItem: mbItem))
        }

        // Apply notch hiding after the system places the items (needs ~1 runloop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyNotchHiding()
        }
    }

    private func removeDummyIcons() {
        dummyEntries.forEach {
            $0.statusItem.isVisible = true   // restore before removing
            NSStatusBar.system.removeStatusItem($0.statusItem)
        }
        dummyEntries.removeAll()
        DebugSettings.shared.hiddenDummyItems = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            OverflowStatusManager.shared.displayItems([])
        }
    }

    // MARK: Notch-based hiding ─────────────────────────────────────────────────
    //
    // === Real MacBook notch behavior (reference) ===
    //
    //  Screen layout (horizontal):
    //   [left safe area] [==NOTCH==] [right safe area]
    //
    //  - auxiliaryTopRightArea.minX  = notch right edge = right safe area LEFT boundary
    //  - Status items accumulate right→left inside the right safe area only
    //  - When items overflow (would extend left of notch right edge), macOS simply
    //    makes them invisible — they are NOT moved to the left of the notch
    //  - The ▾ indicator is itself a status item in the right safe area; it appears
    //    when ANY item is hidden, consuming its own width from the right safe area
    //
    // === Emulation strategy ===
    //
    //  Step 1. Place all dummy items (NSStatusItem) — system lays them out right→left
    //  Step 2. Read each item's screen frame via btn.window.convertToScreen()
    //  Step 3. Items whose LEFT edge (minX) < notchRightEdge are "overflowed"
    //            → set isVisible = false  (removes from bar, frees space)
    //            → add to hiddenItems list for overflow panel
    //  Step 4. After a brief layout settling delay, call displayItems() so the
    //          guillemet is created with the freed space available

    func applyNotchHiding() {
        let s = DebugSettings.shared

        // Prefer simulated notch when active; fall back to real notch detection.
        // On a non-notch Mac without simulation both return hasNotch=false → bail out.
        let isSimulated = s.simulatedNotchEnabled
        let notchInfo: NotchInfo = s.makeSimulatedNotchInfo() ?? NotchDetector.detect()

        guard notchInfo.hasNotch else {
            // No notch of any kind — restore everything
            dummyEntries.forEach { $0.statusItem.isVisible = true }
            s.hiddenDummyItems = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                OverflowStatusManager.shared.displayItems([])
            }
            return
        }

        // Classify each dummy item as overflowed or visible.
        var visible: [(entry: DummyEntry, frame: CGRect)] = []
        var overflowed: [(entry: DummyEntry, frame: CGRect?)] = []

        for entry in dummyEntries {
            if let f = screenFrame(of: entry.statusItem) {
                // minX < notchRightEdge → left edge crosses into notch territory
                if f.minX < notchInfo.rightEdgeX {
                    overflowed.append((entry, f))
                } else {
                    visible.append((entry, f))
                }
            } else {
                // No window frame:
                //   Simulated notch — item couldn't be laid out (bar is full)
                //   Real notch      — macOS has already hidden this item (window detached)
                overflowed.append((entry, nil))
            }
        }

        var logLines = [
            "[DEBUG] applyNotchHiding isSimulated=\(isSimulated)",
            "  notchRight=\(Int(notchInfo.rightEdgeX))",
            "  visible=\(visible.count)  overflowed=\(overflowed.count)",
        ]

        // Simulated notch: manually control isVisible — macOS won't hide items for us.
        // Real notch: macOS already hides overflowed items; never touch isVisible here
        //             or it triggers unwanted layout cascades.
        for item in visible {
            if isSimulated { item.entry.statusItem.isVisible = true }
            logLines.append("  VISIBLE  \(item.entry.menuBarItem.appName): x=\(Int(item.frame.minX))")
        }
        for item in overflowed {
            if isSimulated { item.entry.statusItem.isVisible = false }
            let xStr = item.frame.map { "x=\(Int($0.minX))" } ?? "hidden-by-os"
            logLines.append("  OVERFLOW \(item.entry.menuBarItem.appName): \(xStr)")
        }

        try? logLines.joined(separator: "\n")
            .write(toFile: "/tmp/mbdx_debug_notch.log", atomically: true, encoding: .utf8)

        // Build the hidden item list for the overflow panel.
        // Sort by x descending (rightmost = nearest to notch = shown first/leftmost in panel)
        // Items with no frame (x=0) sort to the end (they were furthest left in the bar)
        let hiddenItems = overflowed
            .sorted { a, b in (a.frame?.minX ?? -1) > (b.frame?.minX ?? -1) }
            .map { $0.entry.menuBarItem }

        s.hiddenDummyItems = hiddenItems

        // Step 4: wait for isVisible=false to settle in the status bar layout,
        // then surface the guillemet + panel through OverflowStatusManager.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            OverflowStatusManager.shared.displayItems(hiddenItems)
        }

    }

    // MARK: Helpers

    /// Returns the screen-coordinate frame of an NSStatusItem's button.
    private func screenFrame(of item: NSStatusItem) -> CGRect? {
        guard let btn = item.button, let window = btn.window else { return nil }
        // btn.convert(btn.bounds, to: nil) → button rect in window coordinates
        // window.convertToScreen()         → window coords → screen coords (Cocoa Y-up)
        let inWindow = btn.convert(btn.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func makeDummyImage(index: Int, color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 3, yRadius: 3)
            color.withAlphaComponent(0.9).setFill()
            path.fill()
            return true
        }
    }
}

// MARK: - SimulatedNotchOverlay ───────────────────────────────────────────────
//
// A floating, click-through window drawn over the menu bar.
// Visually represents the simulated notch (black pill + orange border + "NOTCH" label).
// Only shown in DEBUG mode on non-notched hardware.

final class SimulatedNotchOverlay: NSPanel {

    init(screen: NSScreen) {
        let barH   = NSStatusBar.system.thickness
        let notchW = DebugSettings.simulatedNotchWidth
        let cx     = screen.frame.midX
        let rect   = NSRect(x: cx - notchW / 2,
                            y: screen.frame.maxY - barH,
                            width: notchW,
                            height: barH)

        super.init(contentRect: rect,
                   styleMask:   [.borderless, .nonactivatingPanel],
                   backing:     .buffered,
                   defer:       false)

        // Must appear above menu bar content
        level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        isOpaque             = false
        backgroundColor      = .clear
        hasShadow            = false
        ignoresMouseEvents   = true
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView          = SimulatedNotchView(frame: NSRect(origin: .zero, size: rect.size))
    }
}

/// Draws the notch silhouette: black fill flush against the top edge,
/// rounded bottom corners, plus an orange DEBUG border and label.
private final class SimulatedNotchView: NSView {

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = CGFloat(10)
        let b = bounds

        // Notch shape (rounded bottom, flush top)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.minY + r))
        path.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r),
                       radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: NSPoint(x: b.minX + r, y: b.minY))
        path.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r),
                       radius: r, startAngle: -90, endAngle: 180, clockwise: true)
        path.close()

        NSColor.black.setFill()
        path.fill()

        // Orange dashed border — unmistakably DEBUG
        let border = path.copy() as! NSBezierPath
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.lineWidth = 1.5
        NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
        border.stroke()

        // "NOTCH" label
        let attr: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.9),
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
        ]
        let lbl = "NOTCH" as NSString
        let sz  = lbl.size(withAttributes: attr)
        lbl.draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - sz.height / 2),
                 withAttributes: attr)
    }
}

#endif // DEBUG
