import AppKit
import ApplicationServices

// MARK: - OverflowMode ─────────────────────────────────────────────────────────

enum OverflowMode: String {
    case normal   = "normal"
    case category = "category"

    static var persisted: OverflowMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "overflowDisplayMode") ?? "normal"
            return OverflowMode(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "overflowDisplayMode") }
    }
}

// MARK: - NotchInfo ────────────────────────────────────────────────────────────

struct NotchInfo {
    let hasNotch: Bool
    let leftEdgeX: CGFloat
    let rightEdgeX: CGFloat
}

// MARK: - NotchDetector ────────────────────────────────────────────────────────

enum NotchDetector {
    static func detect(on screen: NSScreen = NSScreen.screens.first ?? NSScreen.main!) -> NotchInfo {
        #if DEBUG
        if let sim = DebugSettings.shared.makeSimulatedNotchInfo() { return sim }
        #endif
        guard #available(macOS 12.0, *),
              let leftArea  = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return NotchInfo(hasNotch: false, leftEdgeX: 0, rightEdgeX: 0)
        }
        let ox        = screen.frame.minX
        let leftEdge  = ox + leftArea.maxX
        let rightEdge = ox + rightArea.minX
        return NotchInfo(hasNotch: rightEdge > leftEdge, leftEdgeX: leftEdge, rightEdgeX: rightEdge)
    }
}

// MARK: - OverflowStatusManager ───────────────────────────────────────────────

final class OverflowStatusManager {

    static let shared = OverflowStatusManager()

    var enumerator: MenuBarEnumerator?

    private var guilemetItem: NSStatusItem?
    private var panelController: OverflowPanelController?
    private var pollTimer: Timer?
    private var lastHiddenCount = -1

    private init() {}

    func start(with enumerator: MenuBarEnumerator) {
        self.enumerator = enumerator
        schedulePoll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        removeGuillemet()
    }

    private func schedulePoll() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer?.tolerance = 0.5
    }

    private func poll() {
        guard let enumerator else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var hidden = enumerator.enumerateHiddenItems()
            #if DEBUG
            hidden.append(contentsOf: DebugSettings.shared.makeDummyHiddenItems())
            DebugSettings.shared.prependPinnedItems(to: &hidden, using: enumerator)
            #endif
            DispatchQueue.main.async { self?.update(hiddenItems: hidden) }
        }
    }

    func forceRefresh() {
        lastHiddenCount = -1
        poll()
    }

    func displayItems(_ items: [MenuBarItem]) {
        assert(Thread.isMainThread)
        lastHiddenCount = -1
        update(hiddenItems: items)
    }

    private func update(hiddenItems: [MenuBarItem]) {
        guard hiddenItems.count != lastHiddenCount else { return }
        lastHiddenCount = hiddenItems.count

        if hiddenItems.isEmpty {
            removeGuillemet()
            panelController?.hidePanel()
        } else {
            ensureGuillemet()
            panelController?.setItems(hiddenItems)
        }
    }

    private func ensureGuillemet() {
        guard guilemetItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title   = "⟫"
        item.button?.font    = .systemFont(ofSize: 13, weight: .semibold)
        item.button?.toolTip = "メニューバーオーバーフロー — 非表示のアイコンを表示"
        item.button?.target  = self
        item.button?.action  = #selector(guilemetClicked)
        guilemetItem = item
        if panelController == nil { panelController = OverflowPanelController() }
    }

    private func removeGuillemet() {
        if let item = guilemetItem {
            NSStatusBar.system.removeStatusItem(item)
            guilemetItem = nil
        }
        panelController?.hidePanel()
    }

    @objc private func guilemetClicked() {
        guard let panel = panelController else { return }
        if panel.isVisible {
            panel.hidePanel()
        } else {
            panel.showPanel(anchoredTo: guilemetItem?.button?.window)
        }
    }
}

// MARK: - OverflowPanel (NSPanel subclass) ─────────────────────────────────────
//
// Subclassing NSPanel to override sendEvent is the only reliable way to
// intercept rightMouseDown on a nonactivatingPanel. Neither
// NSClickGestureRecognizer(buttonMask:1<<1) nor NSView.rightMouseDown(with:)
// are guaranteed to fire because the system may dispatch right-click events
// before gesture recognition completes on panels of this type.

private final class OverflowPanel: NSPanel {
    /// Called when a rightMouseDown event hits this window.
    var onRightClick: ((NSPoint) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let handler = onRightClick {
            let pt = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            handler(pt)
            return   // consume — prevents system context-menu from appearing
        }
        super.sendEvent(event)
    }
}

// MARK: - OverflowPanelController ─────────────────────────────────────────────

final class OverflowPanelController: NSObject {

    private let panel: OverflowPanel
    private let panelContent: OverflowPanelContent
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor:   Any?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panelContent = OverflowPanelContent()
        panel = OverflowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level            = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.isFloatingPanel  = true
        panel.isOpaque         = false
        panel.backgroundColor  = .clear
        panel.hasShadow        = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView      = panelContent
        super.init()

        panel.onRightClick = { [weak self] pt in
            guard let self else { return }
            if let hit = self.panelContent.hitTest(pt),
               let item = Self.findItemView(in: hit) {
                item.triggerRightPress()
            }
        }

        panelContent.onResizeNeeded = { [weak self] size in
            self?.resizePanelAnimated(to: size)
        }
        panelContent.onDismissRequest = { [weak self] in
            self?.hidePanel()
        }
        panelContent.onItemPress = { [weak self] item in
            self?.activateItem(item, showMenu: false)
        }
        panelContent.onItemRightPress = { [weak self] item in
            self?.activateItem(item, showMenu: true)
        }
    }

    func setItems(_ items: [MenuBarItem]) {
        panelContent.setItems(items)
        let sz = panelContent.preferredSize
        if !panel.isVisible {
            panel.setContentSize(sz)
        }
    }

    func showPanel(anchoredTo anchor: NSWindow?) {
        positionPanel(anchoredTo: anchor)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        startMonitors()
    }

    func hidePanel() {
        stopMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        }
    }

    private func activateItem(_ item: MenuBarItem, showMenu: Bool) {
        let ea = (try? String(contentsOfFile: "/tmp/mbdx_click.log")) ?? ""
        try? (ea + "activateItem: bundle=\(item.bundleID ?? "nil") showMenu=\(showMenu) hasElement=\(item.axElement != nil)\n").write(toFile: "/tmp/mbdx_click.log", atomically: true, encoding: .utf8)
        hidePanel()
        #if DEBUG
        if item.bundleID?.hasPrefix("com.debug.") == true {
            let name = item.axDescription.isEmpty ? item.appName : item.axDescription
            let alert = NSAlert()
            alert.messageText     = "DEBUG: \(name)"
            alert.informativeText = """
                このアイコンはデバッグ用のダミーアイテムです。

                ID       : \(item.id.uuidString.prefix(8))…
                appName  : \(item.appName)
                bundleID : \(item.bundleID ?? "(none)")
                isHidden : \(item.isHidden)
                action   : \(showMenu ? "右クリック(ShowMenu)" : "左クリック(Press)")
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        #endif
        guard let element = item.axElement else { return }
        let bundleID = item.bundleID ?? "(nil)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if showMenu {
                // First try AXShowMenu; if unsupported, synthesize a CGEvent right-click
                // at the element's actual screen position.
                let axResult = AXUIElementPerformAction(element, "AXShowMenu" as CFString)
                if axResult != .success {
                    Self.synthesizeRightClick(on: element)
                }
            } else {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result != .success {
                    AXUIElementPerformAction(element, "AXShowMenu" as CFString)
                }
            }
        }
    }

    /// Synthesizes a system-level right mouse click at the center of the given AX element.
    /// Used as a fallback when AXShowMenu is not supported by the element's process.
    private static func synthesizeRightClick(on element: AXUIElement) {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return }

        var pos  = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize,  &size)

        // AX coordinates: origin top-left, y increases downward (same as CGEvent HID tap)
        let pt = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)

        let src  = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown,
                           mouseCursorPosition: pt, mouseButton: .right)
        let up   = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp,
                           mouseCursorPosition: pt, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func positionPanel(anchoredTo anchor: NSWindow?) {
        let screen  = NSScreen.main ?? NSScreen.screens[0]
        let notch   = NotchDetector.detect(on: screen)
        let barH    = NSStatusBar.system.thickness
        let size    = panelContent.preferredSize

        let y = screen.frame.maxY - barH - size.height
        var x: CGFloat
        if let anchorFrame = anchor?.frame {
            x = anchorFrame.midX - size.width / 2
        } else if notch.hasNotch {
            x = notch.leftEdgeX - size.width
        } else {
            x = screen.frame.midX - size.width / 2
        }
        x = max(screen.frame.minX + 4, min(x, screen.frame.maxX - size.width - 4))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    private func resizePanelAnimated(to size: NSSize) {
        guard panel.isVisible, let screen = NSScreen.main else { return }
        let barH     = NSStatusBar.system.thickness
        let midX     = panel.frame.midX
        let newY     = screen.frame.maxY - barH - size.height
        let newX     = max(screen.frame.minX + 4,
                           min(midX - size.width / 2, screen.frame.maxX - size.width - 4))
        let newFrame = NSRect(x: newX, y: newY, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func startMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hidePanel()
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            if event.keyCode == 53 {   // Esc
                self.hidePanel()
            } else {
                self.panelContent.handleKey(event)
            }
        }
    }

    private func stopMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor   { NSEvent.removeMonitor(m) }
        globalMouseMonitor = nil
        globalKeyMonitor   = nil
    }

    /// Walk up the view hierarchy from `view` to find an OverflowItemView.
    private static func findItemView(in view: NSView) -> OverflowItemView? {
        var v: NSView? = view
        while let current = v {
            if let item = current as? OverflowItemView { return item }
            v = current.superview
        }
        return nil
    }
}

// MARK: - OverflowPanelContent ────────────────────────────────────────────────

/// Root content view of the panel. Owns the blur background and switches modes.
final class OverflowPanelContent: NSView {

    var onResizeNeeded:   ((NSSize) -> Void)?
    var onDismissRequest: (() -> Void)?
    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?

    private let blur: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material     = .menu
        v.state        = .active
        v.wantsLayer   = true
        return v
    }()

    // Floating gear button — always visible in top-right corner
    private let settingsButton: NSButton = {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle    = .regularSquare
        btn.isBordered    = false
        let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "表示設定")
        img?.isTemplate   = true
        btn.image         = img
        btn.imageScaling  = .scaleProportionallyDown
        btn.alphaValue    = 0.45
        return btn
    }()

    private var mode: OverflowMode = OverflowMode.persisted
    private var items: [MenuBarItem] = []
    private var categories: [Category] = []

    private var normalView: OverflowNormalView?
    private var categoryView: OverflowCategoryView?
    private var activeContentView: NSView?

    static let cornerRadius: CGFloat = 8

    var preferredSize: NSSize {
        switch mode {
        case .normal:
            return normalPreferredSize
        case .category:
            return categoryView?.preferredPanelSize ?? NSSize(width: 260, height: 200)
        }
    }

    private var normalPreferredSize: NSSize {
        let maxW = (NSScreen.main?.frame.width ?? 1200) - 8
        let w    = max(80, CGFloat(items.count) * OverflowNormalView.itemW + 16)
        return NSSize(width: min(w, maxW), height: 56)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        blur.frame           = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        settingsButton.target = self
        settingsButton.action = #selector(gearTapped)
        addSubview(settingsButton)   // on top of blur

        categories = DataStore.shared.loadCategories()
        refreshContent(animated: false)
    }

    override func layout() {
        super.layout()
        applyRoundedCornerMask()
        let btnSize: CGFloat = 18
        settingsButton.frame = NSRect(x: bounds.maxX - btnSize - 3,
                                      y: bounds.maxY - btnSize - 3,
                                      width: btnSize, height: btnSize)
    }

    private func applyRoundedCornerMask() {
        let path = NSBezierPath(roundedRect: bounds,
                                xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        blur.layer?.mask = mask
    }

    // MARK: Public API

    func setItems(_ items: [MenuBarItem]) {
        self.items      = items
        self.categories = DataStore.shared.loadCategories()
        switch mode {
        case .normal:
            normalView?.configure(with: items)
        case .category:
            categoryView?.setData(items: items, categories: categories)
        }
    }

    func handleKey(_ event: NSEvent) {
        if mode == .category {
            categoryView?.handleKey(event)
        }
    }

    // MARK: Mode switching

    @objc private func gearTapped() {
        let menu     = NSMenu()
        let nItem    = NSMenuItem(title: "通常表示",
                                  action: #selector(setNormalMode), keyEquivalent: "")
        nItem.target = self
        nItem.state  = mode == .normal ? .on : .off
        menu.addItem(nItem)

        let cItem    = NSMenuItem(title: "カテゴリ表示",
                                  action: #selector(setCategoryMode), keyEquivalent: "")
        cItem.target = self
        cItem.state  = mode == .category ? .on : .off
        menu.addItem(cItem)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: settingsButton.bounds.height),
                   in: settingsButton)
    }

    @objc private func setNormalMode()    { switchMode(to: .normal) }
    @objc private func setCategoryMode()  { switchMode(to: .category) }

    private func switchMode(to newMode: OverflowMode) {
        guard newMode != mode else { return }
        mode = newMode
        OverflowMode.persisted = newMode
        normalView   = nil
        categoryView = nil
        refreshContent(animated: true)
    }

    // MARK: Content management

    private func refreshContent(animated: Bool) {
        let newView: NSView
        switch mode {
        case .normal:
            let v = OverflowNormalView()
            v.configure(with: items)
            v.onItemPress      = { [weak self] item in self?.onItemPress?(item) }
            v.onItemRightPress = { [weak self] item in self?.onItemRightPress?(item) }
            normalView = v
            newView    = v

        case .category:
            let v = OverflowCategoryView()
            // Set callbacks BEFORE setData so the initial size notification is received
            v.onItemPress      = { [weak self] item in self?.onItemPress?(item) }
            v.onItemRightPress = { [weak self] item in self?.onItemRightPress?(item) }
            v.onSizeChange     = { [weak self] size in self?.onResizeNeeded?(size) }
            categoryView = v
            v.setData(items: items, categories: categories)
            newView = v
        }

        newView.frame           = blur.bounds
        newView.autoresizingMask = [.width, .height]

        if animated, let old = activeContentView {
            newView.alphaValue = 0
            blur.addSubview(newView, positioned: .below, relativeTo: nil)
            activeContentView  = newView
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                old.animator().alphaValue = 0
                newView.animator().alphaValue = 1
            }) { [weak old] in
                old?.removeFromSuperview()
            }
        } else {
            activeContentView?.removeFromSuperview()
            blur.addSubview(newView)
            activeContentView = newView
        }

        onResizeNeeded?(preferredSize)
    }
}

// MARK: - OverflowNormalView ──────────────────────────────────────────────────

final class OverflowNormalView: NSView {

    static let itemW: CGFloat = 44
    static let itemH: CGFloat = 56

    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?

    private let clipView = NSView()
    private var itemViews: [OverflowItemView] = []

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        clipView.wantsLayer        = true
        clipView.layer?.masksToBounds = true
        clipView.autoresizingMask  = [.width, .height]
        addSubview(clipView)
    }

    func configure(with items: [MenuBarItem]) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []
        for item in items {
            let v = OverflowItemView(
                item:         item,
                onPress:      { [weak self] in self?.onItemPress?(item) },
                onRightPress: { [weak self] in self?.onItemRightPress?(item) }
            )
            clipView.addSubview(v)
            itemViews.append(v)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        clipView.frame = bounds
        let h = bounds.height
        for (i, v) in itemViews.enumerated() {
            v.frame = NSRect(x: CGFloat(i) * Self.itemW, y: 0,
                             width: Self.itemW, height: h)
        }
    }
}

// MARK: - OverflowCategoryView ────────────────────────────────────────────────

final class OverflowCategoryView: NSView {

    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?
    var onSizeChange:     ((NSSize) -> Void)?

    // Slide container (clips its children)
    private let slideClip: NSView = {
        let v = NSView()
        v.wantsLayer            = true
        v.layer?.masksToBounds  = true
        return v
    }()

    private var items:      [MenuBarItem] = []
    private var categories: [Category]   = []

    private enum PageState { case list; case icons(Category) }
    private var pageState: PageState = .list
    private var selectedCategoryIndex  = 0

    private var categoryListPage:  CategoryListView?
    private var categoryIconsPage: CategoryIconListView?

    /// The page currently "at home" (x=0). Used by layout() to keep it filled.
    private var currentPageView: NSView?
    /// True while a slide animation is in progress — prevents layout() from clobbering animated frames.
    private var isPageAnimating = false

    static let listRowH:  CGFloat = 44
    static let panelW:    CGFloat = 240
    static let iconsH:    CGFloat = 56
    static let headerH:   CGFloat = 28

    var preferredPanelSize: NSSize {
        switch pageState {
        case .list:
            let n = visibleCategories().count
            return NSSize(width: Self.panelW,
                          height: CGFloat(max(1, n)) * Self.listRowH)
        case .icons(let cat):
            let catItems = itemsFor(cat)
            let maxW = (NSScreen.main?.frame.width ?? 1200) - 8
            let w    = max(Self.panelW,
                           CGFloat(catItems.count) * OverflowNormalView.itemW + 16)
            return NSSize(width: min(w, maxW),
                          height: Self.headerH + Self.iconsH)
        }
    }

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        slideClip.autoresizingMask = [.width, .height]
        addSubview(slideClip)
    }

    override func layout() {
        super.layout()
        slideClip.frame = bounds
        // Explicitly keep the current page filling the clip.
        // autoresizingMask from a zero-sized parent doesn't work reliably, so we
        // do this manually. The isPageAnimating guard prevents us from overriding
        // the slide-in/slide-out frames set by NSAnimationContext.
        if let page = currentPageView, !isPageAnimating {
            page.frame = slideClip.bounds
        }
    }

    // MARK: Data

    func setData(items: [MenuBarItem], categories: [Category]) {
        self.items      = items
        self.categories = categories
        rebuildCurrentPage(animated: false)
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) {
        switch pageState {
        case .list:
            switch event.keyCode {
            case 125: // ↓
                selectedCategoryIndex = min(selectedCategoryIndex + 1,
                                           max(0, visibleCategories().count - 1))
                categoryListPage?.selectedIndex = selectedCategoryIndex
            case 126: // ↑
                selectedCategoryIndex = max(selectedCategoryIndex - 1, 0)
                categoryListPage?.selectedIndex = selectedCategoryIndex
            case 36, 76, 124: // Return, numpad Enter, →
                let cats = visibleCategories()
                guard selectedCategoryIndex < cats.count else { break }
                navigateTo(cat: cats[selectedCategoryIndex])
            default: break
            }
        case .icons:
            switch event.keyCode {
            case 53, 123: // Esc, ←
                navigateBack()
            default: break
            }
        }
    }

    // MARK: Navigation

    private func navigateTo(cat: Category) {
        pageState = .icons(cat)
        rebuildCurrentPage(animated: true, direction: .forward)
        onSizeChange?(preferredPanelSize)
    }

    private func navigateBack() {
        pageState = .list
        rebuildCurrentPage(animated: true, direction: .backward)
        onSizeChange?(preferredPanelSize)
    }

    // MARK: Page building

    private enum SlideDir { case none, forward, backward }

    private func rebuildCurrentPage(animated: Bool, direction: SlideDir = .none) {
        let oldPage = slideClip.subviews.first
        let newPage: NSView

        switch pageState {
        case .list:
            let cats = visibleCategories()
            let listView = CategoryListView(categories: cats, items: items)
            listView.selectedIndex = selectedCategoryIndex
            listView.onSelect      = { [weak self] cat in self?.navigateTo(cat: cat) }
            categoryListPage  = listView
            categoryIconsPage = nil
            newPage = listView

        case .icons(let cat):
            let catItems = itemsFor(cat)
            let iconsView = CategoryIconListView(
                category:      cat,
                items:         catItems,
                onBack:        { [weak self] in self?.navigateBack() },
                onPress:       { [weak self] item in self?.onItemPress?(item) },
                onRightPress:  { [weak self] item in self?.onItemRightPress?(item) }
            )
            categoryIconsPage = iconsView
            newPage = iconsView
        }

        // Use current slideClip size if available; fall back to preferred size
        let containerW = slideClip.bounds.width  > 0 ? slideClip.bounds.width  : Self.panelW
        let containerH = slideClip.bounds.height > 0 ? slideClip.bounds.height : Self.listRowH * 3

        // No autoresizingMask — layout() manages the current page's frame explicitly
        newPage.frame = NSRect(x: 0, y: 0, width: containerW, height: containerH)

        guard animated, let old = oldPage, direction != .none else {
            oldPage?.removeFromSuperview()
            slideClip.addSubview(newPage)
            currentPageView = newPage
            return
        }

        let slideW  = containerW
        let startX: CGFloat = direction == .forward ?  slideW : -slideW
        newPage.frame      = NSRect(x: startX, y: 0, width: containerW, height: containerH)
        newPage.alphaValue = 0.4
        slideClip.addSubview(newPage)
        currentPageView  = newPage
        isPageAnimating  = true

        let endOldX: CGFloat = direction == .forward ? -slideW : slideW
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration         = 0.18
            ctx.timingFunction   = CAMediaTimingFunction(name: .easeOut)
            old.animator().frame = NSRect(x: endOldX, y: 0, width: containerW, height: containerH)
            old.animator().alphaValue = 0
            newPage.animator().frame  = NSRect(x: 0, y: 0, width: containerW, height: containerH)
            newPage.animator().alphaValue = 1
        }) { [weak self, weak old] in
            old?.removeFromSuperview()
            self?.isPageAnimating = false
            self?.needsLayout = true   // re-layout so the page snaps to correct bounds
        }
    }

    // MARK: Helpers

    private func visibleCategories() -> [Category] {
        categories.filter { cat in
            if cat.id == Category.allItems.id { return true }
            return items.contains { $0.categoryID == cat.id }
        }
    }

    private func itemsFor(_ cat: Category) -> [MenuBarItem] {
        if cat.id == Category.allItems.id { return items }
        return items.filter { $0.categoryID == cat.id }
    }
}

// MARK: - CategoryListView ────────────────────────────────────────────────────

final class CategoryListView: NSView {

    var onSelect: ((Category) -> Void)?

    var selectedIndex: Int = 0 {
        didSet {
            for (i, card) in cardViews.enumerated() {
                card.isSelected = i == selectedIndex
            }
        }
    }

    private var cardViews: [CategoryCardView] = []
    private var orderedCategories: [Category] = []

    init(categories: [Category], items: [MenuBarItem]) {
        super.init(frame: .zero)
        orderedCategories = categories

        for (i, cat) in categories.enumerated() {
            let count: Int
            if cat.id == Category.allItems.id {
                count = items.count
            } else {
                count = items.filter { $0.categoryID == cat.id }.count
            }
            let card         = CategoryCardView(category: cat, count: count)
            card.isSelected  = i == 0
            card.onTap       = { [weak self] in self?.onSelect?(cat) }
            addSubview(card)
            cardViews.append(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w  = bounds.width
        let rH = OverflowCategoryView.listRowH
        for (i, card) in cardViews.enumerated() {
            card.frame = NSRect(x: 0,
                                y: bounds.height - CGFloat(i + 1) * rH,
                                width: w, height: rH)
        }
    }
}

// MARK: - CategoryCardView ────────────────────────────────────────────────────

final class CategoryCardView: NSView {

    let category: Category
    var onTap: (() -> Void)?

    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    private let iconView    = NSImageView()
    private let nameLabel   = NSTextField(labelWithString: "")
    private let countLabel  = NSTextField(labelWithString: "")
    private let chevron     = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered   = false

    init(category: Category, count: Int) {
        self.category = category
        super.init(frame: .zero)
        wantsLayer = true

        let icon = NSImage(systemSymbolName: category.sfSymbol,
                           accessibilityDescription: category.name)
        icon?.isTemplate           = true
        iconView.image             = icon
        iconView.contentTintColor  = .secondaryLabelColor
        addSubview(iconView)

        nameLabel.stringValue = category.name
        nameLabel.font        = .systemFont(ofSize: 13)
        nameLabel.textColor   = .labelColor
        addSubview(nameLabel)

        countLabel.stringValue = "\(count)"
        countLabel.font        = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor   = .secondaryLabelColor
        countLabel.alignment   = .right
        addSubview(countLabel)

        let chevImg = NSImage(systemSymbolName: "chevron.right",
                              accessibilityDescription: nil)
        chevImg?.isTemplate       = true
        chevron.image             = chevImg
        chevron.contentTintColor  = .tertiaryLabelColor
        addSubview(chevron)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovered {
            let alpha: CGFloat = isSelected ? 0.18 : 0.10
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let pad: CGFloat   = 12
        let iconSz: CGFloat = 16
        let chevSz: CGFloat = 10

        iconView.frame = NSRect(x: pad, y: (h - iconSz) / 2,
                                width: iconSz, height: iconSz)
        chevron.frame  = NSRect(x: w - pad - chevSz, y: (h - chevSz) / 2,
                                width: chevSz, height: chevSz)

        countLabel.sizeToFit()
        let cW = max(countLabel.frame.width + 4, 18)
        countLabel.frame = NSRect(x: chevron.frame.minX - cW - 4,
                                  y: (h - 16) / 2, width: cW, height: 16)

        let nameX = iconView.frame.maxX + 8
        let nameW = countLabel.frame.minX - nameX - 4
        nameLabel.frame = NSRect(x: nameX, y: (h - 17) / 2,
                                 width: max(0, nameW), height: 17)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true;  needsDisplay = true }
    override func mouseExited (with event: NSEvent) { isHovered = false; needsDisplay = true }

    @objc private func handleTap() { onTap?() }
}

// MARK: - CategoryIconListView ─────────────────────────────────────────────────

final class CategoryIconListView: NSView {

    private let headerView   = NSView()
    private let backButton   = NSButton()
    private let iconClipView = NSView()
    private var itemViews:   [OverflowItemView] = []

    init(category:    Category,
         items:       [MenuBarItem],
         onBack:      @escaping () -> Void,
         onPress:     @escaping (MenuBarItem) -> Void,
         onRightPress: @escaping (MenuBarItem) -> Void)
    {
        super.init(frame: .zero)
        wantsLayer = true

        // Header
        addSubview(headerView)

        backButton.title          = "← \(category.name)"
        backButton.bezelStyle     = .regularSquare
        backButton.isBordered     = false
        backButton.font           = .systemFont(ofSize: 12, weight: .medium)
        backButton.contentTintColor = .secondaryLabelColor
        backButton.alignment      = .left
        backButtonAction = onBack
        backButton.target = self
        backButton.action = #selector(backTapped)
        headerView.addSubview(backButton)

        // Icon area
        iconClipView.wantsLayer           = true
        iconClipView.layer?.masksToBounds = true
        addSubview(iconClipView)

        for item in items {
            let v = OverflowItemView(
                item:         item,
                onPress:      { onPress(item) },
                onRightPress: { onRightPress(item) }
            )
            iconClipView.addSubview(v)
            itemViews.append(v)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var backButtonAction: (() -> Void)?

    @objc private func backTapped() { backButtonAction?() }

    override func layout() {
        super.layout()
        let w  = bounds.width
        let h  = bounds.height
        let hH = OverflowCategoryView.headerH

        headerView.frame   = NSRect(x: 0, y: h - hH, width: w, height: hH)
        backButton.frame   = NSRect(x: 6, y: 0, width: w - 12, height: hH)
        iconClipView.frame = NSRect(x: 0, y: 0, width: w, height: h - hH)

        let iH = h - hH
        for (i, v) in itemViews.enumerated() {
            v.frame = NSRect(x: CGFloat(i) * OverflowNormalView.itemW,
                             y: 0,
                             width: OverflowNormalView.itemW, height: iH)
        }
    }
}

// MARK: - OverflowItemView ────────────────────────────────────────────────────

final class OverflowItemView: NSView {

    private let imageView  = NSImageView()
    private let label      = NSTextField(labelWithString: "")
    private let labelText: String
    private var onPress:      () -> Void
    private var onRightPress: () -> Void
    private var trackingArea: NSTrackingArea?

    private static var hoverWindow: HoverTooltipWindow?

    init(item: MenuBarItem, onPress: @escaping () -> Void, onRightPress: @escaping () -> Void) {
        self.onPress      = onPress
        self.onRightPress = onRightPress
        self.labelText    = item.axDescription.isEmpty ? item.appName : item.axDescription
        super.init(frame: .zero)

        wantsLayer          = true
        layer?.cornerRadius = 6

        imageView.image           = item.image
        imageView.imageScaling    = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = []
        addSubview(imageView)

        label.stringValue          = labelText
        label.font                 = .systemFont(ofSize: 8, weight: .regular)
        label.textColor            = .secondaryLabelColor
        label.alignment            = .center
        label.lineBreakMode        = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.autoresizingMask     = []
        addSubview(label)

        // Left click — NSClickGestureRecognizer works reliably for left clicks on nonactivatingPanel
        let leftClick = NSClickGestureRecognizer(target: self, action: #selector(handleLeftClick))
        leftClick.buttonMask = 1 << 0
        addGestureRecognizer(leftClick)
        // Right click is handled via rightMouseDown override (gesture recognizer is unreliable
        // for right-clicks on nonactivatingPanel — the system intercepts them first).
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let iconSize: CGFloat = 22
        let labelH:   CGFloat = 12
        let topPad:   CGFloat = 6

        imageView.frame = NSRect(x: (w - iconSize) / 2,
                                 y: h - topPad - iconSize,
                                 width: iconSize, height: iconSize)
        label.frame     = NSRect(x: 2,
                                 y: h - topPad - iconSize - 2 - labelH,
                                 width: w - 4, height: labelH)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .inVisibleRect,
                                         .activeAlways, .mouseMoved],
                               owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        }
        showHoverTooltip(near: event)
    }

    override func mouseMoved(with event: NSEvent) { moveHoverTooltip(near: event) }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().layer?.backgroundColor = NSColor.clear.cgColor
        }
        Self.hoverWindow?.orderOut(nil)
    }

    private func showHoverTooltip(near event: NSEvent) {
        let win = Self.hoverWindow ?? HoverTooltipWindow()
        Self.hoverWindow = win
        win.setText(labelText)
        moveHoverTooltip(near: event)
        win.orderFront(nil)
    }

    private func moveHoverTooltip(near event: NSEvent) {
        guard let win = Self.hoverWindow, let myWindow = window else { return }
        let mouseInWindow = event.locationInWindow
        let mouseInScreen = myWindow.convertToScreen(NSRect(origin: mouseInWindow, size: .zero))
        let tipSize = win.frame.size
        win.setFrameOrigin(NSPoint(x: mouseInScreen.origin.x + 6,
                                   y: mouseInScreen.origin.y - tipSize.height - 4))
    }

    // MARK: - Click

    @objc private func handleLeftClick() {
        flashAndCall(onPress)
    }

    /// Called by OverflowPanelController's local right-click monitor.
    func triggerRightPress() {
        flashAndCall(onRightPress)
    }

    private func flashAndCall(_ action: @escaping () -> Void) {
        let e1 = (try? String(contentsOfFile: "/tmp/mbdx_click.log")) ?? ""
        try? (e1 + "flashAndCall: start\n").write(toFile: "/tmp/mbdx_click.log", atomically: true, encoding: .utf8)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.06
            animator().layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        }) { [weak self] in
            let e2 = (try? String(contentsOfFile: "/tmp/mbdx_click.log")) ?? ""
            try? (e2 + "flashAndCall: completion fired\n").write(toFile: "/tmp/mbdx_click.log", atomically: true, encoding: .utf8)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.06
                self?.animator().layer?.backgroundColor = NSColor.clear.cgColor
            }
            action()
        }
    }
}

// MARK: - HoverTooltipWindow ──────────────────────────────────────────────────

final class HoverTooltipWindow: NSPanel {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero,
                   styleMask:   [.borderless, .nonactivatingPanel],
                   backing:     .buffered,
                   defer:       false)
        level            = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        isOpaque         = false
        backgroundColor  = .clear
        hasShadow        = true
        ignoresMouseEvents = true

        let container = NSVisualEffectView()
        container.material     = .toolTip
        container.blendingMode = .withinWindow
        container.state        = .active
        container.wantsLayer   = true
        container.layer?.cornerRadius = 4

        label.font      = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
    }

    func setText(_ text: String) {
        label.stringValue = text
        let font  = label.font ?? .systemFont(ofSize: 11)
        let attrs = [NSAttributedString.Key.font: font]
        let sz    = (text as NSString).size(withAttributes: attrs)
        setContentSize(NSSize(width: sz.width + 14, height: 20))
    }
}

// MARK: - NSBezierPath + CGPath ───────────────────────────────────────────────

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var pts  = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:    path.move(to: pts[0])
            case .lineTo:    path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo:
                             path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            case .quadraticCurveTo:
                             path.addQuadCurve(to: pts[1], control: pts[0])
            @unknown default:
                if pts[0] != .zero { path.addLine(to: pts[0]) }
            }
        }
        return path
    }
}
