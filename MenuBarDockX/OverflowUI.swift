import AppKit
import ApplicationServices
import SwiftUI

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
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
//
// アイコン切替方式（AppKit 純正）:
//   SwiftUI MenuBarExtra は使用しない。
//   隠れたアイコンが検出されたとき、既存の NSStatusItem のアイコンを ▾ に切り替える。
//   切替は onOverflowModeChanged コールバック経由で AppDelegate が担当する。
//   dead zone（ノッチ内）に押し出された場合も selfInDeadZone フラグで検出し、
//   ▾ 状態を維持する。パネルはグローバルショートカット ⌃⌥⌘M でも開ける。

final class OverflowStatusManager {

    static let shared = OverflowStatusManager()

    var enumerator: MenuBarEnumerator?

    /// AppDelegate の statusItem への弱参照（設定メニューのポップアップに使用）。
    weak var appStatusItem: NSStatusItem?

    /// overflow mode の ON/OFF が切り替わったとき AppDelegate に通知するコールバック。
    /// メインスレッドから呼ばれる。
    var onOverflowModeChanged: ((Bool) -> Void)?

    private var panelController: OverflowPanelController?
    private var pollTimer: Timer?
    private var lastHiddenIDs: Set<UUID> = []
    private var lastHiddenCount = -1
    private var lastSelfInDeadZone = false
    private(set) var isOverflowMode = false
    private var terminationObserver: Any?

    private init() {}

    func start(with enumerator: MenuBarEnumerator, statusItem: NSStatusItem) {
        self.enumerator    = enumerator
        self.appStatusItem = statusItem
        panelController = OverflowPanelController()
        schedulePoll()
        observeAppTermination()
    }

    /// ▾ クリックまたはグローバルショートカットから呼ばれる。
    /// パネルが開いていれば閉じ、閉じていれば開く。
    func togglePanel() {
        guard let pc = panelController else { return }
        if pc.isVisible {
            pc.hidePanel()
        } else {
            // NSStatusItem のウィンドウを anchor として渡す。
            // dead zone にある場合は positionPanel 内で visible zone 右端にフォールバックする。
            pc.showPanel(anchoredTo: appStatusItem?.button?.window)
        }
        #if DEBUG
        ClickLog("[togglePanel] panelWasVisible=\(pc.isVisible)")
        #endif
    }

    /// アプリ終了を即座に検知してパネルを更新する。
    /// 3 秒ポーリングを待たずにアイコンを消す。
    private func observeAppTermination() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 終了直後は AX リストがまだ更新途中の場合があるため短い遅延を挟む
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.forceRefresh()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        exitOverflowMode()
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

        // 自分自身の NSStatusItem が dead zone / ノッチゾーンに入っていないか確認する。
        // ・x < 10          : 完全にオフスクリーン
        // ・x < rightEdge+40: ノッチゾーン内（x≈618 付近が典型）
        // どちらも「見えない」ため overflow 扱いにする。
        let ownX = appStatusItem?.button?.window?.frame.origin.x ?? 9999
        let notchInfo = NotchDetector.detect()
        // 他アプリの隠れアイテム判定とは異なり、自分自身の可視判定には +40 マージンを使わない。
        // rightEdgeX より右にいれば確実に可視ゾーン。
        let selfInDeadZone = ownX < 10
            || (notchInfo.hasNotch && ownX > 0 && ownX < notchInfo.rightEdgeX)
        #if DEBUG
        ClickLog("[poll] ownX=\(Int(ownX)) rightEdge=\(Int(notchInfo.rightEdgeX)) selfInDeadZone=\(selfInDeadZone)")
        #endif

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 保存済み DTO を渡して categoryID・ID を再起動後も復元する。
            let dtos = DataStore.shared.loadItemDTOs()
            var hidden = enumerator.enumerateHiddenItems(merging: dtos)
            #if DEBUG
            hidden.append(contentsOf: DebugSettings.shared.makeDummyHiddenItems())
            DebugSettings.shared.prependPinnedItems(to: &hidden, using: enumerator)
            #endif
            DispatchQueue.main.async {
                self?.update(hiddenItems: hidden, selfInDeadZone: selfInDeadZone)
            }
        }
    }

    func forceRefresh() {
        // lastHiddenIDs はリセットしない。
        // リセットすると「空→空」で変化なしと判定されてアイコン削除が反映されないバグが起きる。
        // ID ベースの比較が自然に差分を検出するため、リセット不要。
        #if DEBUG
        ClickLog("[forceRefresh] lastHiddenIDs=\(lastHiddenIDs.count)")
        #endif
        poll()
    }

    func displayItems(_ items: [MenuBarItem]) {
        assert(Thread.isMainThread)
        lastHiddenIDs = []
        lastHiddenCount = -1
        update(hiddenItems: items)
    }

    private func update(hiddenItems: [MenuBarItem], selfInDeadZone: Bool = false) {
        let newIDs = Set(hiddenItems.map(\.id))
        // 自分が dead zone に入っている場合は「overflow あり」として扱う。
        // 他アプリのアイコンが全部 visible zone に収まっていても
        // MenuBarDockX 自体が見えなくなっているため ▼ への切り替えが必要。
        let effectivelyOverflow = !hiddenItems.isEmpty || selfInDeadZone
        #if DEBUG
        ClickLog("[update] newIDs=\(newIDs.count) selfInDeadZone=\(selfInDeadZone) lastHiddenIDs=\(lastHiddenIDs.count) panelVisible=\(panelController?.isVisible == true)")
        #endif
        // アイテムの内容（ID セット）と selfInDeadZone が変わった場合のみ更新する。
        let stateChanged = newIDs != lastHiddenIDs || selfInDeadZone != lastSelfInDeadZone
        guard stateChanged else {
            #if DEBUG
            ClickLog("[update] SKIP (same state)")
            #endif
            return
        }
        lastHiddenIDs      = newIDs
        lastHiddenCount    = hiddenItems.count
        lastSelfInDeadZone = selfInDeadZone

        if !effectivelyOverflow {
            #if DEBUG
            ClickLog("[update] -> exitOverflowMode + hidePanel(restoreIndicator:false)")
            #endif
            exitOverflowMode()
            panelController?.hidePanel(restoreIndicator: false)
        } else {
            #if DEBUG
            ClickLog("[update] -> enterOverflowMode + setItems(\(hiddenItems.count))")
            #endif
            enterOverflowMode()
            // パネル表示中でも setItems を呼び、消えたアイコンを即座に除去する。
            panelController?.setItems(hiddenItems)
        }
    }

    // MARK: - Overflow mode (NSStatusItem アイコンを ▾ ↔ 通常アイコンに切り替える)

    private func enterOverflowMode() {
        guard !isOverflowMode else { return }
        isOverflowMode = true
        // AppDelegate の NSStatusItem アイコンを ▾ に変更してもらう
        onOverflowModeChanged?(true)
        #if DEBUG
        ClickLog("[enterOverflowMode] isOverflowMode = true")
        #endif
    }

    private func exitOverflowMode() {
        guard isOverflowMode else { return }
        isOverflowMode = false
        // AppDelegate の NSStatusItem アイコンを元に戻してもらう
        onOverflowModeChanged?(false)
        #if DEBUG
        ClickLog("[exitOverflowMode] isOverflowMode = false")
        #endif
    }
}

// MARK: - OverflowPanel ───────────────────────────────────────────────────────
// rightMouseDown は AppKit の通常ディスパッチ経由で NSView 層まで確実に届く。

private final class OverflowPanel: NSPanel {

    // このパネルを唯一の keyWindow 候補にする。
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    #if DEBUG
    override func orderOut(_ sender: Any?) {
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n    ")
        ClickLog("[OverflowPanel orderOut] isVisible=\(isVisible)\n    \(stack)")
        super.orderOut(sender)
    }
    override func setIsVisible(_ flag: Bool) {
        if !flag {
            let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n    ")
            ClickLog("[OverflowPanel setIsVisible(false)] isVisible=\(isVisible)\n    \(stack)")
        }
        super.setIsVisible(flag)
    }
    override func close() {
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n    ")
        ClickLog("[OverflowPanel close()] isVisible=\(isVisible)\n    \(stack)")
        super.close()
    }
    #endif
}

// MARK: - OverflowPanelController ─────────────────────────────────────────────

final class OverflowPanelController: NSObject {

    private let panel: OverflowPanel
    private let panelContent: OverflowPanelContent
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor:   Any?
    private var localLeftMonitor: Any?
    /// オーバーフローパネル位置計算に使うアンカー（インジケーター button window）。
    private weak var anchorPanel: NSWindow?

    /// showPanel/hidePanel の呼び出し世代カウンター。
    /// hidePanel のアニメーション完了ハンドラが showPanel 開始後に発火するレースコンディション
    /// （panel.alphaValue=0 の直接代入が前アニメーションをキャンセルし completion を即時発火させる）
    /// を防ぐために使用する。completion は自分の世代番号を保持し、現在と異なれば orderOut しない。
    private var panelGeneration = 0

    var isVisible: Bool { panel.isVisible }

    override init() {
        panelContent = OverflowPanelContent()
        panel = OverflowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
            // .borderless のみ: .titled を使うとタイトルバー分の高さが contentView の
            // 座標系に加算され、ヒットテストの座標がずれる。
            // canBecomeKey は OverflowPanel で override(true) しているため
            // .titled なしでも makeKeyAndOrderFront で keyWindow になれる。
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        panel.isFloatingPanel    = true
        panel.isOpaque           = false
        // .clear (alpha=0) にすると WindowServer がアルファ合成でクリック通過を判定する。
        // 歯車アイコンの透明ピクセル（歯の間・中央の穴）を経由したクリックが
        // パネルを素通りして背後のウィンドウへ届いてしまう。
        // alpha=0.001 にすることで視覚上は透明に見えるが、WindowServer には
        // 「不透明な領域あり」と認識させクリック通過を防止する。
        panel.backgroundColor    = NSColor(white: 0, alpha: 0.001)
        panel.hasShadow          = true
        // NSPanel のデフォルト hidesOnDeactivate=true はアプリが一瞬でも非アクティブに
        // なった瞬間パネルを自動非表示にする。hidePanel() を経由しないため
        // [hidePanel] ログが出ず、▾ インジケーターも復元されない。
        // false にしてパネルの表示/非表示を自前で完全制御する。
        panel.hidesOnDeactivate  = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView               = panelContent
        super.init()

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
        if panel.isVisible {
            // パネル表示中（アプリ終了などによる動的更新）はフレームを直接更新する。
            // resizePanelAnimated はパネル位置を動かすためグローバルモニターが誤発火するリスクがある。
            // ここでは幅・高さのみ変更し、アンカー基準の位置は positionPanel で再計算する。
            var f = panel.frame
            f.size = sz
            // アンカー基準で下辺を固定したまま幅を変える（パネルが左方向に広がる想定）
            panel.setFrame(f, display: true, animate: false)
        } else {
            panel.setContentSize(sz)
        }
    }

    func showPanel(anchoredTo anchor: NSWindow?) {
        #if DEBUG
        let caller = Thread.callStackSymbols.dropFirst(1).prefix(3).joined(separator: "\n    ")
        ClickLog("[showPanel] called  gen=\(panelGeneration)  caller=\n    \(caller)")
        #endif
        // ① 残存する設定ポップオーバーを閉じる（前回 show で開いたまま残っている場合）。
        //   NSPopover ウィンドウが OverflowPanel より前面に残ると hitTest が届かなくなる。
        panelContent.closeSettingsPopoverIfNeeded()

        // 世代番号を更新する。前の hidePanel のアニメーション完了ハンドラが
        // この showPanel より後に発火しても orderOut をスキップさせるため。
        panelGeneration += 1

        // アンカーウィンドウ（インジケーター button window）をパネル位置計算に使う
        anchorPanel = anchor

        positionPanel(anchoredTo: anchor)
        panelContent.startColorSampling()
        panelContent.ensureLayerOrder()   // solidOverlay 最背面 / settingsButton 最前面を確定

        // ② パネルを先に表示状態にしてからアクティブ化する。
        //   activate → makeKeyAndOrderFront の順では activate が非同期処理のため
        //   キー化が空振りする場合がある。
        //   isVisible=true で OS にウィンドウを登録してから activate → async makeKey の順にする。
        panel.alphaValue = 0
        if !panel.isVisible { panel.setIsVisible(true) }

        // ③ レイアウトパスを同期実行（isVisible 直後に行うことでフレームを確定させる）
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()

        // ④ アクティブ化してから次のイベントループで makeKey する。
        //   activate() は AppKit 内部でイベントをポストするため、同一 run-loop ではまだ
        //   完了していない。async で 1 イテレーション後に makeKeyAndOrderFront を呼ぶことで
        //   activation 完了後に確実にキー化できる。
        //
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panelContent)
            #if DEBUG
            ClickLog("=== showPanel (async makeKey) ===")
            ClickLog("  keyWindow:         \(NSApp.keyWindow as Any)")
            ClickLog("  panel.isKeyWindow: \(panel.isKeyWindow)")
            ClickLog("  firstResponder:    \(panel.firstResponder as Any)")
            ClickLog("  settingsButton.frame: \(panelContent.settingsButtonFrame)")
            #endif
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        startMonitors()
    }

    /// パネルを閉じる。
    /// - Parameter restoreIndicator: true（デフォルト）= 完了後にインジケーターパネルを復元する。
    ///   オーバーフローアイテムが 0 件になった場合など、インジケーター自体が不要なときは false を渡す。
    ///   false にすることで、exitOverflowMode() が隠したインジケーターを
    ///   hidePanel completion が誤って再表示するレースコンディションを防ぐ。
    func hidePanel(restoreIndicator: Bool = true) {
        #if DEBUG
        // 呼び出し元を特定するためスタックの2フレーム目（呼び出し元）を記録する
        let caller = Thread.callStackSymbols.dropFirst().first ?? "unknown"
        ClickLog("[hidePanel] called  caller=\(caller)  panel.isVisible=\(panel.isVisible)  restoreIndicator=\(restoreIndicator)")
        #endif
        // 設定ポップオーバーが開いていれば先に閉じる。
        // NSPopover ウィンドウが OverflowPanel より前面に残ると、次回 showPanel 時に
        // クリックがポップオーバーウィンドウに吸われてしまうため。
        panelContent.closeSettingsPopoverIfNeeded()
        panelContent.stopColorSampling()
        stopMonitors()
        // 世代番号を保持する。完了ハンドラ発火時点で世代が変わっていれば
        // showPanel が呼ばれた後なので orderOut をスキップして panel を生かす。
        let gen = panelGeneration
        _ = restoreIndicator  // NSStatusItem ベースのインジケーターは廃止済み
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }) { [weak self] in
            guard let self else { return }
            guard self.panelGeneration == gen else {
                // showPanel が割り込んだ — orderOut しない
                #if DEBUG
                ClickLog("[hidePanel completion] skipped (generation changed \(gen)→\(self.panelGeneration))")
                #endif
                return
            }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            // NSStatusItem ベースのインジケーターは非表示にしていないため復元不要
            self.anchorPanel = nil
        }
    }

    private func activateItem(_ item: MenuBarItem, showMenu: Bool) {
        if DataStore.shared.overflowSettings.dismissOnClick {
            hidePanel()
        }
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
        _ = item.bundleID  // retained for future logging
        let itemFrame = item.frame   // capture value type before dispatch
        let itemBundle = item.bundleID ?? "?"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            #if DEBUG
            // 要素がサポートするアクション一覧をログ出力（診断用）
            var actionNamesRef: CFArray?
            if AXUIElementCopyActionNames(element, &actionNamesRef) == .success,
               let names = actionNamesRef as? [String] {
                ClickLog("[activateItem] \(itemBundle) supportedActions=\(names)")
            } else {
                ClickLog("[activateItem] \(itemBundle) supportedActions=UNKNOWN")
            }
            // 全 AX 属性をダンプ（AXMenu などの有無を確認する）
            var attrNamesRef: CFArray?
            if AXUIElementCopyAttributeNames(element, &attrNamesRef) == .success,
               let attrNames = attrNamesRef as? [String] {
                ClickLog("[activateItem] \(itemBundle) attributes=\(attrNames)")
                // AXMenu 属性が存在する場合はその内容もダンプ
                if attrNames.contains("AXMenu") {
                    var menuRef: CFTypeRef?
                    let menuResult = AXUIElementCopyAttributeValue(element, "AXMenu" as CFString, &menuRef)
                    ClickLog("[activateItem] \(itemBundle) AXMenu result=\(menuResult.rawValue) value=\(menuRef as Any)")
                    if let menu = menuRef, menuResult == .success {
                        var childrenRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(menu as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                           let children = childrenRef as? [AXUIElement] {
                            ClickLog("[activateItem] \(itemBundle) AXMenu children count=\(children.count)")
                            for child in children {
                                var titleRef: CFTypeRef?
                                let t = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success ? (titleRef as? String ?? "?") : "?"
                                ClickLog("[activateItem]   menuItem title='\(t)'")
                            }
                        }
                    }
                }
            }
            // 要素の現在 AX 位置も確認
            var posRef2: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef2) == .success,
               let pv = posRef2 {
                var axPos = CGPoint.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &axPos)
                ClickLog("[activateItem] \(itemBundle) axPos=\(axPos) itemFrame.midX=\(itemFrame.midX)")
            }
            #endif
            if showMenu {
                // 右クリック（メニュー表示）フォールバックチェーン:
                //
                // 1. AXShowMenu on button — AX API で直接要求
                // 2. AXShowMenu on AXParent — 親要素（NSStatusBarWindow）への試行
                // 3. AXShowMenu on AXWindow — ウィンドウ要素への試行
                // 4. カスタムコンテキストメニュー — Toggle / Quit などを提供するフォールバック
                //
                // 注: macOS Tahoe では hidden な NSStatusBarWindow が layer=0 に降格され
                //     CGEvent による右クリック合成はすべて ControlCenter(layer=25) に
                //     横取りされるため、CGEvent 合成は採用しない。

                var handled = false

                // 1. AXShowMenu on button
                if AXUIElementPerformAction(element, "AXShowMenu" as CFString) == .success {
                    handled = true
                }

                // 2. AXShowMenu on AXParent
                if !handled {
                    var parentRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                       let p = parentRef, CFGetTypeID(p) == AXUIElementGetTypeID() {
                        if AXUIElementPerformAction(p as! AXUIElement, "AXShowMenu" as CFString) == .success {
                            handled = true
                        }
                    }
                }

                // 3. AXShowMenu on AXWindow
                if !handled {
                    var windowRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
                       let w = windowRef, CFGetTypeID(w) == AXUIElementGetTypeID() {
                        if AXUIElementPerformAction(w as! AXUIElement, "AXShowMenu" as CFString) == .success {
                            handled = true
                        }
                    }
                }

                #if DEBUG
                ClickLog("[activateItem] \(itemBundle) AXShowMenu chain handled=\(handled)")
                #endif

                // 4. フォールバック: カスタムコンテキストメニュー
                if !handled {
                    Self.showFallbackMenu(for: item, element: element)
                }
            } else {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result != .success {
                    AXUIElementPerformAction(element, "AXShowMenu" as CFString)
                }
            }
        }
    }

    // MARK: - Fallback context menu

    /// AXShowMenu が使えない場合に MenuBarDockX 独自のコンテキストメニューを表示する。
    /// Toggle（左クリック相当）・Quit の最低限のメニューを提供する。
    private static func showFallbackMenu(for item: MenuBarItem, element: AXUIElement) {
        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)

        let appName = item.appName.isEmpty ? (item.bundleID ?? "App") : item.appName
        let menu = NSMenu(title: appName)

        // ヘッダー（アプリ名・無効）
        let header = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let bundleID = item.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            header.image = NSWorkspace.shared.icon(forFile: url.path)
            header.image?.size = NSSize(width: 16, height: 16)
        }
        menu.addItem(header)
        menu.addItem(.separator())

        // Toggle（左クリック相当）
        let toggleItem = NSMenuItem(
            title: L("Toggle", "トグル"),
            action: #selector(FallbackMenuActionHandler.handleToggle(_:)),
            keyEquivalent: "")
        toggleItem.representedObject = element
        toggleItem.target = FallbackMenuActionHandler.shared
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Quit
        if ownerPID != 0 {
            let quitItem = NSMenuItem(
                title: L("Quit \(appName)", "\(appName) を終了"),
                action: #selector(FallbackMenuActionHandler.handleQuit(_:)),
                keyEquivalent: "")
            quitItem.representedObject = ownerPID as AnyObject
            quitItem.target = FallbackMenuActionHandler.shared
            menu.addItem(quitItem)
        }

        // カーソル位置の下にポップアップ
        let cursorAppKit = NSEvent.mouseLocation
        menu.popUp(positioning: nil,
                   at: NSPoint(x: cursorAppKit.x, y: cursorAppKit.y),
                   in: nil)
        #if DEBUG
        ClickLog("[showFallbackMenu] \(appName) appName shown at \(cursorAppKit)")
        #endif
    }

    /// CGWindowListCopyWindowInfo でアイコン座標付近のウィンドウ ID を探す。
    /// オーナー PID が一致するものを優先し、次に座標が含まれるものを返す。
    private static func findWindowID(near origin: CGPoint,
                                     size: CGSize,
                                     ownerPID: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return nil }

        // アイコンの矩形（AX 座標系）
        let iconRect = CGRect(origin: origin, size: size)

        #if DEBUG
        // メニューバー付近（y < 40）の全ウィンドウをダンプして環境を把握する
        let menuBarWindows = list.filter { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let y = boundsDict["Y"], let h = boundsDict["Height"] else { return false }
            return y < 40 || (y < 0 && y + h > 0)
        }
        for info in menuBarWindows {
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let x = bounds["X"] ?? 0; let y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0; let h = bounds["Height"] ?? 0
            let wnum = info[kCGWindowNumber as String] as? Int ?? -1
            let pid  = info[kCGWindowOwnerPID as String] as? Int ?? -1
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let name  = info[kCGWindowName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            ClickLog("[menuBarWin] id=\(wnum) pid=\(pid) owner='\(owner)' name='\(name)' layer=\(layer) rect=(\(x),\(y),\(w),\(h))")
        }
        #endif

        var bestID: CGWindowID?
        var bestScore = -1

        for info in list {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  let wnum = info[kCGWindowNumber as String] as? Int else { continue }

            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            guard windowRect.intersects(iconRect) else { continue }

            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            var score = 0
            if pid == ownerPID { score += 2 }
            if windowRect.contains(iconRect.center) { score += 1 }

            if score > bestScore {
                bestScore = score
                bestID = CGWindowID(wnum)
                #if DEBUG
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let name  = info[kCGWindowName as String] as? String ?? ""
                ClickLog("[findWindowID] → candidate id=\(wnum) pid=\(pid) owner='\(owner)' name='\(name)' rect=(\(x),\(y),\(w),\(h)) score=\(score)")
                #endif
            }
        }
        #if DEBUG
        ClickLog("[findWindowID] origin=\(origin) ownerPID=\(ownerPID) → windowID=\(bestID as Any) score=\(bestScore)")
        #endif
        return bestID
    }

    private func positionPanel(anchoredTo anchor: NSWindow?) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let notch  = NotchDetector.detect(on: screen)
        // NSStatusBar.system.thickness は 22 を返すことがある（Apple の既知バグ）。
        // screen フレームの差分から正確なメニューバー高さを算出する。
        let barH   = screen.frame.maxY - screen.visibleFrame.maxY
        let size   = panelContent.preferredSize

        let y = screen.frame.maxY - barH - size.height
        var x: CGFloat
        // anchor が visible zone（notchRightEdge より右）にある場合のみアンカー基準で配置。
        // dead zone（notch 内や x≈618）にある anchor を使うとパネルが画面外に出るため、
        // その場合は visible zone 左端（notch 右端直後）を使う。
        let anchorX = anchor?.frame.origin.x ?? -1
        let anchorInVisibleZone = notch.hasNotch
            ? anchorX >= notch.rightEdgeX
            : anchorX > 0
        if let anchorFrame = anchor?.frame, anchorInVisibleZone {
            x = anchorFrame.midX - size.width / 2
        } else if notch.hasNotch {
            // アイコンが dead zone、またはショートカット起動 → ノッチ右端の直後に表示
            x = notch.rightEdgeX + 4
        } else {
            x = screen.frame.midX - size.width / 2
        }
        x = max(screen.frame.minX + 4, min(x, screen.frame.maxX - size.width - 4))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    private func resizePanelAnimated(to size: NSSize) {
        guard panel.isVisible, let screen = NSScreen.main else { return }
        let barH     = screen.frame.maxY - screen.visibleFrame.maxY
        let midX     = panel.frame.midX
        let newY     = screen.frame.maxY - barH - size.height
        let newX     = max(screen.frame.minX + 4,
                           min(midX - size.width / 2, screen.frame.maxX - size.width - 4))
        let newFrame = NSRect(x: newX, y: newY, width: size.width, height: size.height)
        #if DEBUG
        ClickLog("[resizePanelAnimated] \(panel.frame) → \(newFrame)")
        #endif
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func startMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let mouseLoc   = NSEvent.mouseLocation
            let panelFrame = self.panel.frame
            let inPanel    = panelFrame.contains(mouseLoc)
            #if DEBUG
            ClickLog("[GLOBAL leftMouseDown] mouseLocation=\(mouseLoc)  panelFrame=\(panelFrame)  inPanel=\(inPanel)")
            #endif
            // AX 有効時はグローバルモニターが自アプリのイベントも捕捉する。
            // パネル内クリック（ポップオーバー CGEventTap 経由含む）では hidePanel しない。
            guard !inPanel else { return }
            self.hidePanel()
        }
        localLeftMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            guard event.window === self.panel else { return event }
            let loc = event.locationInWindow
            #if DEBUG
            ClickLog("[LOCAL  leftMouseDown] window=OverflowPanel  loc=\(loc)  panelFrame=\(self.panel.frame)")
            #endif
            // 歯車エリアのクリックは GearButton.mouseDown / gearTapped に委ねる
            let gearRect = self.panelContent.settingsButtonFrame.insetBy(dx: -6, dy: -6)
            guard !gearRect.contains(loc) else { return event }
            // ポップオーバーが表示中はトランジェント動作に委ねる（CGEventTap が消費済み）
            guard !self.panelContent.isSettingsPopoverShown else { return event }
            // タブバークリックはカテゴリ切り替えに委ねる（パネルを閉じない）
            if let tabRect = self.panelContent.contentTabBarFrame, tabRect.contains(loc) { return event }
            // アイコン行クリック・ドラッグ開始は onItemPress / ドラッグ処理に委ねる（パネルを閉じない）
            // ※ ドラッグ中に hidePanel すると mouseUp 前にパネルが消えてしまうため
            if let iconRect = self.panelContent.contentIconAreaFrame, iconRect.contains(loc) { return event }
            // パネル内の非歯車・非タブ・非アイコンクリック → パネルを閉じる
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.hidePanel()
            }
            return event
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
        if let m = localLeftMonitor { NSEvent.removeMonitor(m) }
        localLeftMonitor = nil
    }

}

// MARK: - PassthroughView ─────────────────────────────────────────────────────

/// マウスイベントとカーソルを完全に透過させる NSView。solidOverlay 専用。
///
/// - hitTest → nil    : イベント連鎖から除外（クリックが背後のビューへ届く）
/// - resetCursorRects : 何もしない（カーソル矩形を登録させない）
/// - discardCursorRects: 初期化時に既存カーソル矩形を強制削除
///
/// ※ NSView に disablesCursorRects プロパティはなく（それは NSWindow のメソッド）、
///    resetCursorRects() の override が NSView レベルの正しい対処法。
private final class PassthroughView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// カーソル矩形を一切登録しない。
    override func resetCursorRects() { }

    /// トラッキングエリアを生成しない。
    /// これにより solidOverlay 上でのカーソル変化・ホバーイベントが完全に抑制される。
    override func updateTrackingAreas() { }

    /// カーソル変更イベントを無効化。
    override func cursorUpdate(with event: NSEvent) { }
}

// MARK: - GearButton ──────────────────────────────────────────────────────────
//
// hover 時に 1.15 倍スケールアップ + alphaValue をアニメーションする NSButton サブクラス。
// baseAlpha: 非 hover 時のアルファ値。toggleEditMode が 0.45 (通常) / 1.0 (編集中) を設定する。

// MARK: - GearButton (NSView ベース) ──────────────────────────────────────────
//
// NSButton + NSImage の内部実装では ButtonCell がピクセル単位のヒット判定を行い、
// 歯車アイコンの透明部分でクリックが通らない問題が発生する。
// NSView を直接継承して描画・ヒット判定・アクション送出をすべて自前で実装し、
// 矩形全体（透明部分含む）を確実にクリック可能にする。
//
private final class GearButton: NSView {

    // MARK: Properties

    /// 表示する SF Symbol / NSImage。セットすると即再描画。
    var image: NSImage? { didSet { needsDisplay = true } }

    /// isTemplate=true の Symbol に適用するティント色。
    /// NSButton.contentTintColor 相当を自前で実装。
    var contentTintColor: NSColor? { didSet { needsDisplay = true } }

    /// 非 hover 時のアルファ値。外部から設定する。
    var baseAlpha: CGFloat = 0.45 {
        didSet { guard !isHovered else { return }; alphaValue = baseAlpha }
    }

    /// アクション送出先。NSButton.target / action と同じ命名で互換性を保つ。
    var action: Selector?
    weak var target: AnyObject?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: Drawing
    //
    // wantsUpdateLayer = false により AppKit は draw(_:) を呼び出し、
    // その結果を layer.contents に書き込む（標準パス）。
    // makeBackingLayer() の override は行わない。
    // override すると AppKit が layer.contents への書き込み先を確保できなくなり、
    // draw() の出力が画面に反映されなくなる。
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        #if DEBUG
        ClickLog("[GearButton] draw called  bounds=\(bounds)  image=\(image != nil ? "set" : "NIL")")
        #endif
        image?.draw(in: bounds)
    }

    // MARK: Hit test
    //
    // NSView の hitTest は透明ピクセルを除外しない。
    // bounds.contains で矩形全体（透明部分含む）をクリック可能にする。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    // MARK: First mouse / responder

    // 非アクティブ状態でのクリックを活性化消費せずそのまま受け取る。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        ClickLog("[GearButton] mouseDown  isKey=\(window?.isKeyWindow ?? false)  firstResponder=\(window?.firstResponder as Any)")
        #endif
        _ = target?.perform(action, with: self)
    }

    // MARK: Hover tracking

    private var isHovered   = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovered else { return }
        isHovered = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
        animateScale(to: 1.15)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = baseAlpha
        }
        animateScale(to: 1.0)
    }

    // MARK: Debug layout logging

    #if DEBUG
    override func layout() {
        super.layout()
        ClickLog("[GearButton] frame=\(frame)")
    }
    #endif

    // MARK: Helpers

    private func animateScale(to scale: CGFloat) {
        let anim                    = CABasicAnimation(keyPath: "transform.scale")
        anim.toValue               = scale
        anim.duration              = 0.12
        anim.timingFunction        = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode              = .forwards
        anim.isRemovedOnCompletion = false
        layer?.add(anim, forKey: "gearHoverScale")
    }
}

// MARK: - OverflowPanelContent ────────────────────────────────────────────────

/// Root content view of the panel.
/// NSVisualEffectView を使わない純 NSView 実装。
/// 背景は solidOverlay の layer.backgroundColor にサンプリング色を直接描画する。
/// blur / vibrancy / material はすべて無効 — メニューバーの CGWindowListCreateImage
/// サンプリング色をそのまま表示することで、視覚的に最もメニューバーに近い色調を得る。
final class OverflowPanelContent: NSView {

    var onResizeNeeded:   ((NSSize) -> Void)?
    var onDismissRequest: (() -> Void)?
    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?

    // ── ソリッドオーバーレイ ─────────────────────────────────────────────────
    // PassthroughView: hitTest=nil + ignoresMouseEvents=true でイベントを完全透過。
    // settingsButton / アイコン行のクリックを妨げない。
    private let solidOverlay: PassthroughView = {
        let v = PassthroughView()
        v.wantsLayer = true
        // hitTest は PassthroughView で nil 固定 → イベントは背後のビューへ透過
        return v
    }()

    // ── 設定ボタン（ギア）────────────────────────────────────────────────────
    // GearButton: hover スケール / 明暗色自動切替を内蔵した NSButton サブクラス。
    // wantsLayer = true + zPosition = 9999 で solidOverlay より確実に前面に固定。
    // frame は layout() で hitSize(28pt) に設定し、クリック判定をアイコン(18pt)より広げる。
    private let settingsButton: GearButton = {
        let btn = GearButton(frame: .zero)
        // SF Symbol "gearshape" を 18pt / medium weight で指定
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let img = NSImage(systemSymbolName: "gearshape",
                          accessibilityDescription: "表示設定")?
                          .withSymbolConfiguration(cfg)
        img?.isTemplate  = true
        btn.image        = img   // draw() で contentTintColor とともに描画される
        btn.alphaValue   = 0.45
        // wantsLayer は GearButton.init で設定済み
        return btn
    }()

    private var mode: OverflowDisplayMode = DataStore.shared.overflowSettings.displayMode
    private var items:      [MenuBarItem] = []
    private var categories: [Category]   = []

    private var normalView:       OverflowNormalView?
    private var tabPanelView:     OverflowTabPanelView?
    private var activeContentView: NSView?
    private var settingsPopover:  NSPopover?
    /// closeSettingsPopoverIfNeeded() でプログラム的に閉じる場合に true にする。
    /// popoverDidClose がプログラム的クローズを検知して誤再オープンするのを防ぐ。
    private var popoverClosingProgrammatically = false

    // ── 編集モード ──────────────────────────────────────────────────────────
    private(set) var isEditMode = false

    /// localLeftMonitor でヒット判定に使う歯車ボタンのフレーム（パネルコンテンツ座標系）
    var settingsButtonFrame: NSRect { settingsButton.frame }

    /// localLeftMonitor でポップオーバー開閉状態を参照するための公開プロパティ
    var isSettingsPopoverShown: Bool { settingsPopover?.isShown == true }

    /// タブバーエリアをパネルコンテンツ座標系で返す（category モード時のみ non-nil）。
    /// localLeftMonitor でタブクリックをパネル閉じから除外するために使う。
    var contentTabBarFrame: NSRect? {
        guard let tp = tabPanelView else { return nil }
        return convert(tp.tabBarFrame, from: tp)
    }

    /// アイコン行エリアをパネルコンテンツ座標系で返す。
    /// localLeftMonitor でアイコンクリック・ドラッグ開始をパネル閉じから除外するために使う。
    /// アイコン行はドラッグや onItemPress で自己完結するため、ここで hidePanel しない。
    var contentIconAreaFrame: NSRect? {
        // category モード: OverflowTabPanelView 内のアイコンビューのフレームを変換
        if let tp = tabPanelView, let ivFrame = tp.iconViewFrame {
            return convert(ivFrame, from: tp)
        }
        // flat モード: normalView 全体がアイコン行
        if let nv = normalView {
            return convert(nv.bounds, from: nv)
        }
        return nil
    }

    // 非アクティブ状態でのクリックを活性化消費せずそのままビューに届ける。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        ClickLog("[PanelContent] mouseDown  isKey=\(self.window?.isKeyWindow ?? false)  firstResponder=\(self.window?.firstResponder as Any)")
        #endif
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // ① settingsButton（GearButton）を expanded frame で最優先判定する。
        //
        //    「frame.contains」で 20×20pt の枠を使うと、歯車の歯間の透明ピクセルや
        //    SF Symbol の内部パディング外縁でクリックが外れやすい。
        //    insetBy(dx:dy:) で負方向に拡張し、実効ヒット領域を約 32×32pt に広げる。
        //
        //    dx=-6: 左 +6pt（アプリアイコン列とは 4pt 以上の余白を保つ）
        //    dy=-6: 上下各 +6pt（メニューバー境界までの余白内に収まる）
        let expandedGear = settingsButton.frame.insetBy(dx: -6, dy: -6)
        if expandedGear.contains(point) {
            #if DEBUG
            ClickLog("[PanelContent] hitTest -> GearButton (expanded)  gearFrame=\(settingsButton.frame)  expandedGear=\(expandedGear)  point=\(point)")
            #endif
            return settingsButton
        }

        // ② それ以外は AppKit の通常カスケードに委ねる
        let result = super.hitTest(point)
        #if DEBUG
        ClickLog("[PanelContent] hitTest -> \(result.map { String(describing: type(of: $0)) } ?? "nil")  point=\(point)")
        #endif
        return result
    }

    // macOS 標準メニューと揃える角丸（HIG 推奨: 4–6pt）
    static let cornerRadius: CGFloat = 5
    // パネル上下に入れる余白。メニューバーとの接続部分に自然な隙間を作る。
    static let vertPad: CGFloat = 5

    // ── グラデーションサンプリング ──────────────────────────────────────────
    private var colorSamplingTimer: Timer?
    private var sampledRawImage:    CGImage?   // 補正前の幅全体×1px キャプチャ画像

    // MARK: Preferred size

    var preferredSize: NSSize {
        let base: NSSize
        switch mode {
        case .flat:
            base = normalPreferredSize
        case .category:
            base = tabPanelView?.preferredSize
                ?? NSSize(width: 260, height: OverflowTabBar.tabH + OverflowNormalView.itemH)
        }
        return NSSize(width: base.width, height: base.height + Self.vertPad * 2)
    }

    private var normalPreferredSize: NSSize {
        let maxW = (NSScreen.main?.frame.width ?? 1200) - 8
        let w    = max(80, CGFloat(items.count) * OverflowNormalView.itemW + 16)
        return NSSize(width: min(w, maxW), height: OverflowNormalView.itemH)
    }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // ── NSView レイヤー設定 ────────────────────────────────────────────
        // NSView なので masksToBounds = true が安全に使える（CABackdropLayer 問題なし）
        wantsLayer = true
        layer?.cornerRadius  = Self.cornerRadius
        layer?.masksToBounds = true   // 全サブビューを角丸でクリップ

        // ① solidOverlay — 最背面のグラデーション描画ビュー
        // layer.contents に CGImage をセット。contentsGravity = .resize で縦ストレッチ。
        // self.masksToBounds が角丸クリップを担うため solidOverlay 自身の設定は不要。
        // positioned: .below, relativeTo: nil → 既存サブビュー全ての後ろに固定
        solidOverlay.layer?.contentsGravity     = .resize
        solidOverlay.layer?.magnificationFilter = .linear   // 縦伸張を滑らかに補間
        solidOverlay.discardCursorRects()                   // 既存カーソル矩形を強制削除
        addSubview(solidOverlay, positioned: .below, relativeTo: nil)

        // ② activeContentView — refreshContent() で settingsButton の直下に挿入
        settingsButton.target = self
        settingsButton.action = #selector(gearTapped)
        addSubview(settingsButton)  // ③ settingsButton — 暫定前面（ensureLayerOrder で確定）

        // settingsButton の位置は layout() で手動設定する（AutoLayout 不使用）。
        // AutoLayout にすると topAnchor の constant 調整で視覚位置が狂うことが判明したため廃止。

        applyGradient()
        categories = DataStore.shared.loadCategories()
        refreshContent(animated: false)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let h = bounds.height

        // solidOverlay はパネル全面を覆う最背面ビュー
        solidOverlay.frame = bounds

        // settingsButton: 旧手動フレーム式を 20pt ボタン向けに維持する。
        // 元の式: y = h - vertPad - hitSize + 3 は「パネル最上部付近」を意図したもの。
        // hitTest は PanelContent.hitTest で frame.contains を使うため
        // AutoLayout なしでも透明部分を含む矩形全体のクリックが正しく機能する。
        let hitSize: CGFloat = 20
        let w = bounds.width
        // center Y を元の 28pt ボタンと揃える。
        // 元式: y = h - vertPad - 28 + 3 → centerY = h - vertPad - 28 + 3 + 14 = h - 16
        // 20pt:  y = h - vertPad - 20 - 1 → centerY = h - vertPad - 20 - 1 + 10 = h - 16 ✓
        settingsButton.frame = NSRect(x: w - hitSize - 4,
                                      y: h - Self.vertPad - hitSize - 1,
                                      width: hitSize, height: hitSize)
        #if DEBUG
        ClickLog("[GearButton] frame=\(settingsButton.frame)  panelSize=\(bounds.size)")
        #endif

        // activeContentView を GearButton の左端より 4pt 手前で打ち切ることで
        // OverflowTabButton が物理的に重なってクリックを奪わないようにする。
        let gearLeft = settingsButton.frame.minX
        activeContentView?.frame = NSRect(x: 0, y: Self.vertPad,
                                          width: max(0, gearLeft - 4),
                                          height: max(0, h - Self.vertPad * 2))

        // フレーム確定後に Z-order を再確定
        // AutoLayout / Core Animation の再合成で subview 順序が変わる場合への対策
        ensureLayerOrder()
    }

    // MARK: Color Sampling

    /// パネル表示中に 1 秒間隔でメニューバー色を再サンプリングする。
    /// ライト/ダーク切り替え・壁紙変更・背後ウィンドウの変化に自動追従する。
    func startColorSampling() {
        #if DEBUG
        DebugColorBarWindow.shared.show()
        #endif
        resampleNow()   // 表示と同時に即座にサンプリング
        colorSamplingTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            self?.resampleNow()
        }
        colorSamplingTimer?.tolerance = 0.2  // CPU wake 最小化
    }

    func stopColorSampling() {
        colorSamplingTimer?.invalidate()
        colorSamplingTimer = nil
        #if DEBUG
        DebugColorBarWindow.shared.hide()
        #endif
    }

    private func resampleNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = MenuBarGradientSampler.sampleRaw()
            DispatchQueue.main.async {
                self?.sampledRawImage = image
                self?.applyGradient()
                #if DEBUG
                DebugColorBarWindow.shared.updateImage(image)
                #endif
            }
        }
    }

    // MARK: Layer order

    /// Z-order を明示的に確定させる。showPanel() から呼ばれる。
    ///   solidOverlay   → 最背面（PassthroughView + ignoresMouseEvents で完全透過）
    ///   activeContentView → 中間
    ///   settingsButton → 最前面
    func ensureLayerOrder() {
        // ① subview 配列の順序を確定
        //    AppKit に bringSubviewToFront はないため addSubview(positioned:) で等価操作
        addSubview(solidOverlay,   positioned: .below, relativeTo: nil)  // 最背面
        if let content = activeContentView {
            addSubview(content,    positioned: .above, relativeTo: nil)  // 中間
        }
        addSubview(settingsButton, positioned: .above, relativeTo: nil)  // 最前面

        // ② CALayer の zPosition で二重保証
        //    AutoLayout / Core Animation の再合成後も順序が崩れない
        solidOverlay.layer?.zPosition       =  -1000
        activeContentView?.layer?.zPosition =      0
        // EditDragOverlay が 99998 / ghostView が 99999 を使うため、
        // settingsButton はそれらより高い 100000 で確実に最前面に固定する。
        settingsButton.layer?.zPosition     = 100000
    }

    // MARK: Gradient rendering

    /// キャプチャ画像（sampledRawImage）に補正を適用し solidOverlay に描画する。
    ///
    /// - layer.contents に幅全体×1px の CGImage をセット
    /// - layer.contentsRect でパネルの画面 X 位置に対応するスライスを指定
    ///   → 横方向の色がメニューバーの対応位置と完全一致する
    /// - layer.opacity で不透明度を制御（アイコン層には無影響）
    func applyGradient() {
        let settings = DataStore.shared.overflowSettings

        // 方式B: raw → ガウスぼかし → 色補正（CIFilter パイプライン）
        // blurRadius=30 で虹色縞を解消しつつメニューバーの大まかな色分布を保持する。
        let corrected: CGImage? = sampledRawImage.flatMap {
            MenuBarGradientSampler.processImage(
                $0,
                blurRadius:  MenuBarGradientSampler.defaultBlurRadius,
                brightness:  settings.blendBrightness,
                saturation:  settings.blendSaturation
            )
        }

        solidOverlay.layer?.contents        = corrected
        solidOverlay.layer?.contentsGravity = .resize
        solidOverlay.layer?.opacity         = Float(settings.panelOpacity)

        // パネルの画面上の水平位置に合わせて contentsRect を計算
        // contentsRect は正規化 UV 座標 (0…1)。画像の該当スライスのみ描画する。
        if let screen   = NSScreen.screens.first,
           let winFrame = self.window?.frame,
           screen.frame.width > 0 {
            let screenW = screen.frame.width
            let panelX  = winFrame.minX - screen.frame.minX   // スクリーン相対 X
            let panelW  = winFrame.width
            let u  = max(0, min(1,     panelX / screenW))
            let uw = max(0, min(1 - u, panelW / screenW))
            solidOverlay.layer?.contentsRect = CGRect(x: u, y: 0, width: uw, height: 1)
        }

        // ギアアイコン色をサンプリング色の明度に応じて自動調整
        // 背景が暗いほど明るい (#E8ECF5) 色、明るい背景には暗い色を使う。
        updateGearIconColor()
    }

    /// サンプリング画像（または外観モード）から推定した輝度を基に歯車アイコンの色を更新する。
    private func updateGearIconColor() {
        let isDark: Bool
        if let raw = sampledRawImage {
            isDark = estimateBrightness(of: raw) < 0.55
        } else {
            // サンプル未取得時はシステム外観で判定
            isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        // contentTintColor: isTemplate=true の SF Symbol に色を適用 (macOS 14+)
        settingsButton.contentTintColor = isDark
            ? NSColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1.0)  // #E8ECF5 — 明るい歯車
            : NSColor(white: 0.20, alpha: 1.0)                          // ダーク歯車
    }

    /// CGImage（メニューバーサンプリング画像）の知覚輝度を推定する。
    /// 中央 1 ピクセルを 1×1 にリサイズして平均 RGB から輝度を計算する。
    private func estimateBrightness(of cgImage: CGImage) -> CGFloat {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return 0.5 }

        // 1×1 の RGBA ビットマップコンテキストに中央ピクセルを描画
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        // 画像全体を 1×1 に縮小（中央輝度の近似として全体平均を使用）
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return 0.5 }

        let ptr = data.bindMemory(to: UInt8.self, capacity: 4)
        let r = CGFloat(ptr[0]) / 255
        let g = CGFloat(ptr[1]) / 255
        let b = CGFloat(ptr[2]) / 255
        // ITU-R BT.709 知覚輝度
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: Public API

    func setItems(_ items: [MenuBarItem]) {
        self.items      = items
        self.categories = DataStore.shared.loadCategories()
        switch mode {
        case .flat:
            normalView?.configure(with: items)
        case .category:
            tabPanelView?.setData(items: items, categories: categories)
        }
    }

    func handleKey(_ event: NSEvent) {
        // タブバー方式ではキーボードナビゲーションは将来対応
    }

    // MARK: Edit mode

    /// 編集モードを ON/OFF する。
    /// アイコンに枠線を表示し、ドラッグ並び替え・右クリックカテゴリ変更を有効化する。
    func toggleEditMode() {
        isEditMode.toggle()
        normalView?.isEditMode   = isEditMode
        tabPanelView?.isEditMode = isEditMode
        // ギアボタンを編集中は完全不透明にして状態を視覚的に示す
        // GearButton.baseAlpha を更新することで hover 退場時の戻り先アルファも自動更新される
        settingsButton.baseAlpha = isEditMode ? 1.0 : 0.45
    }

    // カテゴリ割り当てメニュー用ラッパー（NSMenuItem.representedObject に格納）
    private final class CategoryAssignmentBox: NSObject {
        let item: MenuBarItem
        let categoryID: UUID?
        init(_ item: MenuBarItem, categoryID: UUID?) { self.item = item; self.categoryID = categoryID }
    }

    /// 編集モード中の右クリックでカテゴリ割り当てメニューを表示する。
    private func showCategoryMenu(for item: MenuBarItem) {
        let menu = NSMenu()
        let header = NSMenuItem(title: L("Assign Category", "カテゴリを割り当て"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for cat in categories {
            let mi = NSMenuItem(title: cat.name,
                                action: #selector(categoryMenuSelected(_:)),
                                keyEquivalent: "")
            mi.representedObject = CategoryAssignmentBox(item, categoryID: cat.id)
            mi.target = self
            mi.state  = (item.categoryID == cat.id) ? .on : .off
            menu.addItem(mi)
        }

        // 「未分類」オプション
        let none = NSMenuItem(title: "未分類",
                              action: #selector(categoryMenuSelected(_:)),
                              keyEquivalent: "")
        none.representedObject = CategoryAssignmentBox(item, categoryID: nil)
        none.target = self
        none.state  = (item.categoryID == nil) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(none)

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    @objc private func categoryMenuSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CategoryAssignmentBox else { return }
        let targetID = box.item.id
        // ローカル配列を更新
        if let idx = items.firstIndex(where: { $0.id == targetID }) {
            items[idx].categoryID = box.categoryID
        }
        // DTO を永続化
        var dtos = DataStore.shared.loadItemDTOs()
        if let idx = dtos.firstIndex(where: { $0.id == targetID }) {
            dtos[idx].categoryID = box.categoryID
        } else {
            var dto = MenuBarItemDTO(from: box.item)
            dto.categoryID = box.categoryID
            dtos.append(dto)
        }
        DataStore.shared.saveItemDTOs(dtos)
        refreshContent(animated: false)
    }

    /// ドラッグ→タブドロップによるカテゴリ割当（categoryMenuSelected と同じ永続化ロジック）。
    private func assignCategory(_ item: MenuBarItem, to categoryID: UUID) {
        let targetID = item.id
        if let idx = items.firstIndex(where: { $0.id == targetID }) {
            items[idx].categoryID = categoryID
        }
        var dtos = DataStore.shared.loadItemDTOs()
        if let idx = dtos.firstIndex(where: { $0.id == targetID }) {
            dtos[idx].categoryID = categoryID
        } else {
            var dto = MenuBarItemDTO(from: item)
            dto.categoryID = categoryID
            dtos.append(dto)
        }
        DataStore.shared.saveItemDTOs(dtos)
        // カテゴリ割り当て後は「すべて」タブに戻す。
        // 割り当て先タブを表示すると次のドラッグで同じアイコンを誤って再移動しやすいため、
        // 未分類アイコンを含む「すべて」タブを表示することで連続分類ワークフローを改善する。
        refreshContent(animated: false, selectCategoryID: Category.allItems.id)
    }

    /// ドラッグ並び替え後に呼ばれる。sortOrder を更新して永続化する。
    private func handleReorder(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < items.count,
              toIndex   >= 0, toIndex   < items.count else { return }

        var reordered = items
        let moved = reordered.remove(at: fromIndex)
        reordered.insert(moved, at: toIndex)
        for i in reordered.indices { reordered[i].sortOrder = i }
        items = reordered

        // DTO の sortOrder を更新して永続化
        var dtos = DataStore.shared.loadItemDTOs()
        for item in reordered {
            if let idx = dtos.firstIndex(where: { $0.id == item.id }) {
                dtos[idx].sortOrder = item.sortOrder
            }
        }
        DataStore.shared.saveItemDTOs(dtos)
        refreshContent(animated: false)
    }

    // MARK: Mode switching

    /// 設定ポップオーバーが開いていれば閉じる。
    /// hidePanel / showPanel から呼ぶことで NSPopover ウィンドウが OverflowPanel より
    /// 前面に残り続けるバグ（クリックがポップオーバーウィンドウに吸われる）を防ぐ。
    func closeSettingsPopoverIfNeeded() {
        popoverClosingProgrammatically = true
        defer { popoverClosingProgrammatically = false }
        if let pop = settingsPopover, pop.isShown { pop.close() }
        settingsPopover = nil
    }

    @objc private func gearTapped() {
        #if DEBUG
        ClickLog("[gearTapped] settingsPopover.isShown=\(settingsPopover?.isShown ?? false)")
        #endif
        // 既に開いていれば閉じる
        if let pop = settingsPopover, pop.isShown { pop.close(); return }

        let vc = OverflowSettingsViewController()
        vc.currentEditMode = isEditMode

        // 表示モード変更
        vc.onDisplayModeChange = { [weak self] newMode in
            self?.switchMode(to: newMode)
        }

        // アイコン幅変更 → 現在のコンテンツを再構成してリサイズ
        vc.onIconWidthChange = { [weak self] _ in
            guard let self else { return }
            self.normalView   = nil
            self.tabPanelView = nil
            self.refreshContent(animated: false)
        }

        // 背景透過度変更 → opacity のみ即時反映（再サンプル不要）
        vc.onPanelOpacityChange    = { [weak self] _ in self?.applyGradient() }
        // なじみ補正変更 → CIFilter を再適用（rawImage はそのまま、再サンプル不要）
        vc.onBlendCorrectionChange = { [weak self]   in self?.applyGradient() }
        // 編集モードトグル
        vc.onEditModeToggle = { [weak self, weak vc] in
            self?.toggleEditMode()
            vc?.currentEditMode = self?.isEditMode ?? false
        }

        let popover = NSPopover()
        popover.delegate           = self   // popoverDidClose でギア再クリックを検知
        popover.contentViewController = vc
        popover.behavior              = .transient
        _ = vc.view   // loadView + viewDidLoad を確定させてからサイズを取得
        popover.contentSize = vc.view.frame.size
        popover.show(relativeTo: settingsButton.bounds,
                     of:         settingsButton,
                     preferredEdge: .minY)
        settingsPopover = popover
    }

    private func switchMode(to newMode: OverflowDisplayMode) {
        guard newMode != mode else { return }
        mode = newMode
        var settings = DataStore.shared.overflowSettings
        settings.displayMode = newMode
        DataStore.shared.overflowSettings = settings
        normalView   = nil
        tabPanelView = nil
        refreshContent(animated: true)
    }

    // MARK: Content management

    /// コンテンツビューを再構築する。
    /// - Parameter selectCategoryID: category モードで強制選択したいカテゴリ ID（nil = 維持）
    private func refreshContent(animated: Bool, selectCategoryID: UUID? = nil) {
        let newView: NSView
        switch mode {
        case .flat:
            let v = OverflowNormalView()
            v.configure(with: items)
            v.isEditMode  = isEditMode
            v.onItemPress = { [weak self] item in self?.onItemPress?(item) }
            // 編集モード中は右クリックをカテゴリ割り当てメニューに振り替える
            v.onItemRightPress = { [weak self] item in
                guard let self else { return }
                if self.isEditMode { self.showCategoryMenu(for: item) }
                else               { self.onItemRightPress?(item) }
            }
            v.onReorder = { [weak self] from, to in self?.handleReorder(from: from, to: to) }
            normalView = v
            newView    = v

        case .category:
            let v = OverflowTabPanelView()
            // Set callbacks BEFORE setData so the initial size notification is received
            v.onItemPress = { [weak self] item in self?.onItemPress?(item) }
            v.onItemRightPress = { [weak self] item in
                guard let self else { return }
                if self.isEditMode { self.showCategoryMenu(for: item) }
                else               { self.onItemRightPress?(item) }
            }
            v.onSizeChange     = { [weak self] size in
                guard let self else { return }
                // OverflowTabPanelView.preferredSize はコンテンツ高さのみ（vertPad を含まない）。
                // resizePanelAnimated にはパネル全体高さ（コンテンツ + vertPad×2）が必要なため補正する。
                // これを怠るとパネルが 10px 低くなり、タブバーがアイコン行に重なってアイコンが隠れる。
                let panelSize = NSSize(width: size.width, height: size.height + Self.vertPad * 2)
                self.onResizeNeeded?(panelSize)
            }
            v.onCategoryAssign = { [weak self] item, categoryID in
                self?.assignCategory(item, to: categoryID)
            }
            v.isEditMode = isEditMode
            tabPanelView = v
            v.setData(items: items, categories: categories, preferCategoryID: selectCategoryID)
            newView = v
        }

        // solidOverlay の上・settingsButton の下に配置（アイコンは solidOverlay より前面）
        // フレームは layout() が確定させるため、ここでは vertPad を含む近似値を設定
        let initH = max(0, bounds.height - Self.vertPad * 2)
        newView.frame = NSRect(x: 0, y: Self.vertPad, width: bounds.width, height: initH)

        if animated, let old = activeContentView {
            newView.alphaValue = 0
            addSubview(newView, positioned: .below, relativeTo: settingsButton)
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
            addSubview(newView, positioned: .below, relativeTo: settingsButton)
            activeContentView = newView
        }

        onResizeNeeded?(preferredSize)
    }
}

// MARK: - OverflowPanelContent + NSPopoverDelegate ───────────────────────────

extension OverflowPanelContent: NSPopoverDelegate {
    /// NSPopover クローズ後のクリーンアップ。
    ///
    /// かつて「inGear なら再オープン」ロジックがあったが、
    /// popoverDidClose → gearTapped → 新ポップオーバー → 即 close → popoverDidClose
    /// という無限ループを引き起こすため削除した。
    ///
    /// 歯車ボタンのトグル動作は以下で実現する:
    ///   • 歯車クリック（ポップオーバー未表示）→ GearButton.mouseDown → gearTapped → open
    ///   • 歯車クリック（ポップオーバー表示中）→ .transient が close → ここで nil → done
    func popoverDidClose(_ notification: Notification) {
        #if DEBUG
        ClickLog("[popoverDidClose] closed")
        #endif
        settingsPopover = nil
    }
}

// MARK: - OverflowTabBar ──────────────────────────────────────────────────────
//
// カテゴリ表示モードのタブバー。
// タブ幅の合計がパネル幅に収まる場合は1行、超える場合は2行折り返しになる。

final class OverflowTabBar: NSView {

    static let tabH: CGFloat = 26

    var onSelect: ((Category) -> Void)?

    private var tabButtons: [OverflowTabButton] = []

    /// 現在表示中のタブ数。preferredSize の最低幅計算に使用する。
    var tabCount: Int { tabButtons.count }

    /// 各タブのフレーム（tabBar 座標系）とカテゴリ。ドラッグ式カテゴリ割当に使用する。
    var tabCategoryFrames: [(frame: NSRect, category: Category)] {
        tabButtons.map { ($0.frame, $0.category) }
    }

    func configure(categories: [Category], selected: Category?) {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons = []

        for cat in categories {
            let btn = OverflowTabButton(category: cat)
            btn.isSelected = cat.id == selected?.id
            btn.onTap = { [weak self] in self?.selectTab(btn) }
            addSubview(btn)
            tabButtons.append(btn)
        }
        needsLayout = true
    }

    private func selectTab(_ tapped: OverflowTabButton) {
        tabButtons.forEach { $0.isSelected = $0 === tapped }
        onSelect?(tapped.category)
    }

    /// タブ幅の合計がパネル幅 `width` を超える場合は 2 行になるので tabH * 2 を返す。
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let total = tabButtons.reduce(CGFloat(0)) { $0 + $1.intrinsicTabWidth }
        return total <= width ? Self.tabH : Self.tabH * 2
    }

    override func layout() {
        super.layout()
        guard !tabButtons.isEmpty else { return }

        let w     = bounds.width
        let tH    = Self.tabH
        let total = tabButtons.reduce(CGFloat(0)) { $0 + $1.intrinsicTabWidth }

        if total <= w {
            // 1 行
            var x: CGFloat = 0
            for btn in tabButtons {
                let bw = btn.intrinsicTabWidth
                btn.frame = NSRect(x: x, y: 0, width: bw, height: tH)
                x += bw
            }
        } else {
            // 2 行: 上行 (y = tH) / 下行 (y = 0) に分割
            var row1: [OverflowTabButton] = []
            var row2: [OverflowTabButton] = []
            var runW: CGFloat = 0
            for btn in tabButtons {
                let bw = btn.intrinsicTabWidth
                if runW + bw <= w {
                    row1.append(btn)
                    runW += bw
                } else {
                    row2.append(btn)
                }
            }
            var x: CGFloat = 0
            for btn in row1 {
                btn.frame = NSRect(x: x, y: tH, width: btn.intrinsicTabWidth, height: tH)
                x += btn.intrinsicTabWidth
            }
            x = 0
            for btn in row2 {
                btn.frame = NSRect(x: x, y: 0, width: btn.intrinsicTabWidth, height: tH)
                x += btn.intrinsicTabWidth
            }
        }
    }
}

// MARK: - OverflowTabButton ───────────────────────────────────────────────────

final class OverflowTabButton: NSView {

    let category: Category
    var onTap: (() -> Void)?

    var isSelected: Bool = false {
        didSet {
            needsDisplay = true
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// テキスト幅 + 横パディング
    var intrinsicTabWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        return (category.name as NSString).size(withAttributes: attrs).width + 18
    }

    init(category: Category) {
        self.category = category
        super.init(frame: .zero)
        wantsLayer = true

        label.stringValue = category.name
        label.font        = .systemFont(ofSize: 12)
        label.textColor   = .secondaryLabelColor
        label.alignment   = .center
        label.autoresizingMask = [.width, .height]
        addSubview(label)

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 自身の frame 内のクリックを受け取る。
    /// hitTest(_:) の point は【親ビュー座標系】で渡される。
    /// bounds（自身のローカル座標）と比較すると、origin=(0,0) の基準がズレるため
    /// 後から追加されたボタンほど広い範囲を誤ってキャプチャしてしまう。
    /// frame（親座標系での矩形）と比較することで正しい判定になる。
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        label.frame = bounds
        #if DEBUG
        ClickLog("[OverflowTabButton:\(category.name)] frame=\(frame)")
        #endif
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        } else if isHovered {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
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

    @objc private func tapped() { onTap?() }
}

// MARK: - OverflowTabPanelView ─────────────────────────────────────────────────
//
// カテゴリ表示モードのメインビュー。
// 上部: OverflowTabBar（カテゴリ切り替えタブ）
// 下部: OverflowNormalView（選択カテゴリのアイコン行）

final class OverflowTabPanelView: NSView {

    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?
    var onSizeChange:     ((NSSize) -> Void)?
    /// ドラッグ→タブドロップでカテゴリ割当が確定したときに呼ばれる。
    var onCategoryAssign: ((MenuBarItem, UUID) -> Void)?

    /// 編集モードを内部の OverflowNormalView に伝播する。
    var isEditMode = false {
        didSet {
            iconView?.isEditMode = isEditMode
            // 編集モード ON 時にカテゴリゾーンを更新（タブ位置が確定していれば）
            if isEditMode { updateCategoryZonesForDrag() }
        }
    }

    private let tabBar   = OverflowTabBar()
    private var iconView: OverflowNormalView?

    private var allItems:   [MenuBarItem] = []
    private var categories: [Category]   = []
    private var selectedCategory: Category?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        tabBar.onSelect = { [weak self] cat in
            self?.selectCategory(cat)
        }
        addSubview(tabBar)
    }

    // MARK: Public API

    /// items/categories を更新してビューを再構築する。
    /// - Parameter preferCategoryID: この ID のカテゴリを優先して初期選択する。
    ///   指定がない場合は前回選択を維持し、前回選択が存在しなければ先頭カテゴリを選ぶ。
    func setData(items: [MenuBarItem], categories: [Category], preferCategoryID: UUID? = nil) {
        self.allItems   = items
        self.categories = categories

        let visible = visibleCategories()
        if let id = preferCategoryID,
           let cat = visible.first(where: { $0.id == id }) {
            // assignCategory 後など、強制的に特定カテゴリへ移動させたい場合
            selectedCategory = cat
        } else if selectedCategory == nil || !visible.contains(where: { $0.id == selectedCategory?.id }) {
            // 現在の選択が存在し続ける場合は維持、なければ先頭へ
            selectedCategory = visible.first
        }

        tabBar.configure(categories: visible, selected: selectedCategory)
        rebuildIconView()
        notifySizeChange()
    }

    var preferredSize: NSSize {
        let screenW  = (NSScreen.main?.frame.width ?? 1200) - 8
        let filtered = itemsFor(selectedCategory)
        let iconW    = CGFloat(filtered.count) * OverflowNormalView.itemW + 16

        // カテゴリモードではタブが 6 本以上並ぶため、アイコン幅より広い最低幅を確保する。
        // tabBar.totalTabWidth はタブ全幅（2行折り返しの場合は上行分）の近似値。
        // 簡易計算: タブ本数 × 平均タブ幅(80pt)の半分を最低幅として使う。
        let tabMinW  = CGFloat(tabBar.tabCount) * 80 / 2   // 2行折り返し時の想定上行幅
        let minW:   CGFloat = max(280, tabMinW, iconW)
        let w       = min(minW, screenW)
        let tabH    = tabBar.preferredHeight(forWidth: w)
        return NSSize(width: w, height: tabH + OverflowNormalView.itemH)
    }

    /// タブバーのフレーム（OverflowTabPanelView 座標系）。localLeftMonitor の除外判定に使う。
    var tabBarFrame: NSRect { tabBar.frame }

    /// アイコン行ビューのフレーム（OverflowTabPanelView 座標系）。localLeftMonitor の除外判定に使う。
    var iconViewFrame: NSRect? { iconView?.frame }

    // MARK: Private

    private func selectCategory(_ cat: Category) {
        selectedCategory = cat
        // タブボタンの選択状態を更新する（configure で再生成しないと isSelected が反映されない）
        tabBar.configure(categories: visibleCategories(), selected: cat)
        rebuildIconView()
        notifySizeChange()
    }

    /// 指定 ID のカテゴリをタブ選択する（外部から呼ぶ用）。
    /// assignCategory 後に refreshContent で新規生成されたビューに対して呼ぶ。
    func selectCategoryByID(_ id: UUID) {
        let visible = visibleCategories()
        guard let cat = visible.first(where: { $0.id == id }) else { return }
        tabBar.configure(categories: visible, selected: cat)
        selectedCategory = cat
        rebuildIconView()
        notifySizeChange()
    }

    private func rebuildIconView() {
        iconView?.removeFromSuperview()
        let v = OverflowNormalView()
        v.configure(with: itemsFor(selectedCategory))
        v.onItemPress      = { [weak self] item in self?.onItemPress?(item) }
        v.onItemRightPress = { [weak self] item in self?.onItemRightPress?(item) }
        v.onCategoryAssign = { [weak self] item, categoryID in self?.onCategoryAssign?(item, categoryID) }
        // 編集モードが ON の状態でタブを切り替えた場合に状態を引き継ぐ
        v.isEditMode = isEditMode
        addSubview(v)
        iconView = v
        needsLayout = true
    }

    private func notifySizeChange() {
        onSizeChange?(preferredSize)
    }

    override func layout() {
        super.layout()
        let w    = bounds.width
        let h    = bounds.height
        let tabH = tabBar.preferredHeight(forWidth: w)
        tabBar.frame    = NSRect(x: 0, y: h - tabH, width: w, height: tabH)
        iconView?.frame = NSRect(x: 0, y: 0, width: w, height: OverflowNormalView.itemH)
        // レイアウト確定後にカテゴリゾーンを更新（編集モード中のみ有効）
        if isEditMode { updateCategoryZonesForDrag() }
    }

    /// タブボタンの位置を dragOverlay 座標系のゾーンとして iconView に渡す。
    ///
    /// 座標系の関係（全て origin が (0,0) のため等価）:
    ///   dragOverlay 座標 = clipView 座標 = iconView 座標 = OverflowTabPanelView 座標
    ///
    /// よってタブバーを tabBar.frame.minY だけオフセットすれば dragOverlay 座標に変換できる。
    private func updateCategoryZonesForDrag() {
        guard let iconView else { return }
        // OverflowTabPanelView.layout() 内から呼ばれるため、tabBar 自身の layout()
        // （タブボタン配置）はまだ実行されていない可能性がある。
        // layoutSubtreeIfNeeded() で強制的に確定させてからフレームを読む。
        tabBar.layoutSubtreeIfNeeded()
        let tabBarOriginY = tabBar.frame.minY
        let zones: [(rect: NSRect, categoryID: UUID)] = tabBar.tabCategoryFrames.compactMap { tabFrame, category in
            // "全アイテム" タブへのドロップは意味がないため除外する
            if category.id == Category.allItems.id { return nil }
            let rect = NSRect(
                x: tabFrame.minX,
                y: tabFrame.minY + tabBarOriginY,
                width: tabFrame.width,
                height: tabFrame.height
            )
            return (rect: rect, categoryID: category.id)
        }
        #if DEBUG
        ClickLog("[updateCategoryZonesForDrag] tabBarOriginY=\(tabBarOriginY)  zones=\(zones.map { "(\($0.rect.origin.x.rounded()),\($0.rect.origin.y.rounded()),\($0.rect.width.rounded())x\($0.rect.height.rounded()))" })")
        #endif
        iconView.updateCategoryZones(zones)
    }

    // MARK: Helpers

    private func visibleCategories() -> [Category] {
        categories.filter { cat in
            // 組み込みカテゴリ（isBuiltin = true）は常に表示する。
            // → アイテムが未分類でも全 6 タブが表示され、ユーザーが分類操作を始められる。
            // カスタムカテゴリはアイテムが割り当てられている場合のみ表示する。
            if cat.isBuiltin { return true }
            return allItems.contains { $0.categoryID == cat.id }
        }
    }

    private func itemsFor(_ cat: Category?) -> [MenuBarItem] {
        guard let cat else { return allItems }
        if cat.id == Category.allItems.id { return allItems }
        return allItems.filter { $0.categoryID == cat.id }
    }
}

// MARK: - OverflowNormalView ──────────────────────────────────────────────────

final class OverflowNormalView: NSView {

    /// DataStore の iconWidth を参照することで設定変更が即時反映される。
    static var itemW: CGFloat { DataStore.shared.overflowSettings.iconWidth }
    static let itemH: CGFloat = 38

    var onItemPress:      ((MenuBarItem) -> Void)?
    var onItemRightPress: ((MenuBarItem) -> Void)?
    /// 編集モードのドラッグ並び替え完了時に呼ばれる。
    var onReorder: ((Int, Int) -> Void)?
    /// 編集モードのドラッグ→タブドロップでカテゴリ割当が確定したときに呼ばれる。
    var onCategoryAssign: ((MenuBarItem, UUID) -> Void)?

    // configure(with:) で渡されたアイテム。onCategoryAssign のインデックス→アイテム変換に使用。
    private var currentItems: [MenuBarItem] = []

    // ── 編集モード ──────────────────────────────────────────────────────────
    var isEditMode = false {
        didSet {
            itemViews.forEach { $0.isEditMode = isEditMode }
            // 編集モード中はゴーストビューが clipView 端でクリップされるのを防ぐ。
            // masksToBounds = false にすることでゴーストが clipView の外に出ても見える。
            clipView.layer?.masksToBounds = !isEditMode
            if isEditMode { installDragOverlay() }
            else          { removeDragOverlay() }
        }
    }

    private let clipView = NSView()
    private var itemViews: [OverflowItemView] = []

    // ドラッグ操作用のオーバーレイ（編集モード中のみ存在）
    private var dragOverlay: EditDragOverlay?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        clipView.wantsLayer        = true
        clipView.layer?.masksToBounds = true
        clipView.autoresizingMask  = [.width, .height]
        addSubview(clipView)
    }

    func configure(with items: [MenuBarItem]) {
        currentItems = items
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = []
        for item in items {
            let v = OverflowItemView(
                item:         item,
                onPress:      { [weak self] in self?.onItemPress?(item) },
                onRightPress: { [weak self] in self?.onItemRightPress?(item) }
            )
            v.isEditMode = isEditMode
            clipView.addSubview(v)
            itemViews.append(v)
        }
        needsLayout = true
        // 既存のドラッグオーバーレイを再インストール（アイテムが変わったため）
        if isEditMode { installDragOverlay() }
    }

    override func layout() {
        super.layout()
        clipView.frame = bounds
        let h = bounds.height
        for (i, v) in itemViews.enumerated() {
            v.frame = NSRect(x: CGFloat(i) * Self.itemW, y: 0,
                             width: Self.itemW, height: h)
        }
        dragOverlay?.frame = clipView.bounds
    }

    // MARK: - Edit drag overlay

    private func installDragOverlay() {
        dragOverlay?.removeFromSuperview()
        let overlay = EditDragOverlay(frame: clipView.bounds)
        overlay.itemViews = itemViews
        overlay.onReorder = { [weak self] from, to in self?.onReorder?(from, to) }
        overlay.onCategoryAssign = { [weak self] fromIndex, categoryID in
            guard let self, fromIndex < self.currentItems.count else { return }
            self.onCategoryAssign?(self.currentItems[fromIndex], categoryID)
        }
        clipView.addSubview(overlay)
        dragOverlay = overlay
    }

    private func removeDragOverlay() {
        dragOverlay?.removeFromSuperview()
        dragOverlay = nil
    }

    /// カテゴリドロップゾーンを更新する。OverflowTabPanelView が layout 後に呼ぶ。
    func updateCategoryZones(_ zones: [(rect: NSRect, categoryID: UUID)]) {
        dragOverlay?.categoryZones = zones
    }
}

// MARK: - EditDragOverlay ─────────────────────────────────────────────────────
//
// 編集モード中にアイコン行の上に重ねる透明ビュー。
// mouseDown/mouseDragged/mouseUp でドラッグ並び替えを実現する。
// ドラッグ中はゴーストビューとドロップ位置インジケーターを表示する。

private final class EditDragOverlay: NSView {

    var itemViews: [OverflowItemView] = []
    var onReorder: ((Int, Int) -> Void)?

    /// カテゴリドロップゾーン (overlay 座標系でのタブ矩形, カテゴリ UUID)。
    /// OverflowTabPanelView が layout 後に updateCategoryZones() 経由でセットする。
    var categoryZones: [(rect: NSRect, categoryID: UUID)] = []
    var onCategoryAssign: ((Int, UUID) -> Void)?

    // ドラッグ状態
    private(set) var isDragging       = false
    private var dragStartIndex:   Int?
    private var ghostView:        NSView?
    private var dropIndicator:    NSView?
    private var categoryHighlight: NSView?

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Hit test
    //
    // ドラッグ中だけ self を返してイベントを受け取る。
    // 非ドラッグ時は nil を返し、イベントを背後の OverflowItemView に透過させる。
    // これにより「ギアボタン 1 クリック」「通常クリックでアイコン起動」が妨げられない。
    // bounds チェックは省略 — isDragging = true のとき nextEvent ループが全イベントを消費するため
    // 境界外クリックが他ビューに届く危険性はない。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result: NSView? = isDragging ? self : nil
        #if DEBUG
        if result != nil {
            ClickLog("[EditDragOverlay] hitTest -> self (isDragging=true)")
        }
        #endif
        return result
    }

    // MARK: - Public API (OverflowItemView.mouseDown から呼ばれる)

    /// ドラッグ並び替えを開始する。
    ///
    /// OverflowItemView.mouseDown で呼ばれ、window.nextEvent ループを回す。
    /// ループ中は isDragging = true なので hitTest が self を返し、
    /// 後続のドラッグ・アップイベントもこのビューが受け取る。
    func beginInteractiveReorder(startIndex: Int, startEvent: NSEvent) {
        guard let window else { return }

        // isDragging を先に true にして hitTest が self を返す状態にしてから
        // firstResponder を取得する。順序が逆だと nextEvent が届かないことがある。
        isDragging     = true
        dragStartIndex = startIndex

        // overlay 自身の zPosition を ghostView (99999) より 1 だけ低い値にセット。
        // これにより overlay が ghostView の下に潜らず、かつ settingsButton (100000) より前面に出ない。
        wantsLayer = true
        layer?.zPosition = 99998

        window.makeFirstResponder(self)

        let localStart = convert(startEvent.locationInWindow, from: nil)
        var dragCurrentX = localStart.x
        var dragCurrentY = localStart.y
        showGhost(at: itemViews[startIndex].frame, startX: localStart.x)

        // zPosition / isDragging の変更を Core Animation に即時コミットする。
        // flush() がないと変更が次フレームまで遅延し、ghostView が 1 フレームだけ
        // 他のビューの背後に潜る現象が起きる。
        CATransaction.flush()

        // 同期イベントループ: leftMouseDragged / leftMouseUp を順次処理
        loop: while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch event.type {
            case .leftMouseDragged:
                guard let ghost = ghostView else { break }
                let local = convert(event.locationInWindow, from: nil)
                let dx = local.x - dragCurrentX
                let dy = local.y - dragCurrentY
                ghost.frame.origin.x += dx
                ghost.frame.origin.y += dy
                dragCurrentX = local.x
                dragCurrentY = local.y

                // カテゴリゾーン（タブ領域）に入ったら対象タブをハイライト
                let inZone = categoryZones.first(where: { $0.rect.contains(local) })
                #if DEBUG
                if !categoryZones.isEmpty {
                    ClickLog("[drag] local=(\(local.x.rounded()),\(local.y.rounded()))  zones=\(categoryZones.count)  inZone=\(inZone != nil)")
                }
                #endif
                if let zone = inZone {
                    dropIndicator?.removeFromSuperview()
                    dropIndicator = nil
                    showCategoryHighlight(at: zone.rect)
                } else {
                    clearCategoryHighlight()
                    updateDropIndicator(at: targetIndex(for: local.x))
                }

            case .leftMouseUp:
                let local = convert(event.locationInWindow, from: nil)
                ghostView?.removeFromSuperview();      ghostView = nil
                dropIndicator?.removeFromSuperview();  dropIndicator = nil
                clearCategoryHighlight()

                if let zone = categoryZones.first(where: { $0.rect.contains(local) }),
                   let from = dragStartIndex {
                    // タブ上でドロップ → カテゴリ割当
                    #if DEBUG
                    ClickLog("[mouseUp] DROP on category zone=\(zone.rect)  from=\(from)  categoryID=\(zone.categoryID)")
                    #endif
                    onCategoryAssign?(from, zone.categoryID)
                } else {
                    #if DEBUG
                    ClickLog("[mouseUp] DROP on icon row  local=(\(local.x.rounded()),\(local.y.rounded()))  zones=\(categoryZones.count)  inZone=false")
                    #endif
                    // アイコン行内でドロップ → 並び替え
                    let targetIdx = targetIndex(for: local.x)
                    if let from = dragStartIndex, targetIdx != from {
                        onReorder?(from, targetIdx)
                    }
                }
                dragStartIndex = nil
                break loop

            default: break
            }
        }

        isDragging = false
    }

    // MARK: - Helpers

    /// ドラッグ先のタブをアクセントカラーでハイライトする。
    private func showCategoryHighlight(at rect: NSRect) {
        if categoryHighlight?.frame == rect { return }  // 変化なし
        clearCategoryHighlight()
        let v = NSView(frame: rect)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        v.layer?.cornerRadius    = 4
        v.layer?.zPosition       = 99997
        v.layer?.isOpaque        = false
        v.layer?.masksToBounds   = false
        addSubview(v)
        categoryHighlight = v
    }

    private func clearCategoryHighlight() {
        categoryHighlight?.removeFromSuperview()
        categoryHighlight = nil
    }

    private func showGhost(at frame: NSRect, startX: CGFloat) {
        let g = NSView(frame: frame)
        g.wantsLayer = true
        g.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        g.layer?.cornerRadius    = 6
        g.layer?.borderColor     = NSColor.white.withAlphaComponent(0.55).cgColor
        g.layer?.borderWidth     = 1.5
        // zPosition 最大値で確実に最前面（overlay=99998 より高い）
        g.layer?.zPosition       = 99999
        // 半透明背景が正しく描画されるよう isOpaque = false にする
        // masksToBounds = false でゴーストが clipView の角丸によってクリップされない
        g.layer?.isOpaque        = false
        g.layer?.masksToBounds   = false
        addSubview(g, positioned: .above, relativeTo: nil)
        ghostView = g
    }

    private func updateDropIndicator(at index: Int) {
        dropIndicator?.removeFromSuperview()
        guard index < itemViews.count else { return }
        let x         = itemViews[index].frame.minX
        let indicator = NSView(frame: NSRect(x: x - 1, y: 5, width: 2, height: bounds.height - 10))
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius    = 1
        addSubview(indicator)
        dropIndicator = indicator
    }

    private func targetIndex(for x: CGFloat) -> Int {
        let w = OverflowNormalView.itemW
        guard w > 0 else { return 0 }
        return max(0, min(itemViews.count - 1, Int(x / w)))
    }
}


// MARK: - OverflowItemView ────────────────────────────────────────────────────

final class OverflowItemView: NSView {

    private let imageView  = NSImageView()
    private let labelText: String   // ホバーツールチップ用（表示ラベルは廃止）
    private var onPress:      () -> Void
    private var onRightPress: () -> Void
    private var trackingArea: NSTrackingArea?

    private static var hoverWindow: HoverTooltipWindow?

    /// 編集モード中は破線ボーダーを描画し、通常クリックを無効化する（ドラッグが優先）。
    var isEditMode = false {
        didSet { needsDisplay = true }
    }

    init(item: MenuBarItem, onPress: @escaping () -> Void, onRightPress: @escaping () -> Void) {
        self.onPress      = onPress
        self.onRightPress = onRightPress
        self.labelText    = item.axDescription.isEmpty ? item.appName : item.axDescription
        super.init(frame: .zero)

        wantsLayer          = true
        layer?.cornerRadius = 6

        imageView.image            = item.image
        imageView.imageScaling     = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = []
        addSubview(imageView)

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
        imageView.frame = NSRect(x: (w - iconSize) / 2,
                                 y: (h - iconSize) / 2,
                                 width: iconSize, height: iconSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEditMode else { return }
        // 編集モード: 破線の白枠を描画してドラッグ可能であることを示す
        NSColor.white.withAlphaComponent(0.40).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
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

    // MARK: - Mouse events

    /// 編集モード中の mouseDown を EditDragOverlay に転送してドラッグを開始する。
    ///
    /// EditDragOverlay.hitTest は非ドラッグ時に nil を返すため、
    /// 通常の hitTest ではこのビューが受け取る。
    /// ここで overlay を探して beginInteractiveReorder を呼ぶことで
    /// 「1 クリック = ドラッグ開始」が実現できる。
    override func mouseDown(with event: NSEvent) {
        guard isEditMode else {
            // 編集モード外: 通常の AppKit イベント連鎖へ
            super.mouseDown(with: event)
            return
        }
        // ホバーツールチップをドラッグ開始前に閉じる（mouseExited はドラッグ中に発火しないため）
        Self.hoverWindow?.orderOut(nil)
        // 兄弟ビュー（同じ clipView の中）から EditDragOverlay を探す
        guard let overlay = superview?.subviews.compactMap({ $0 as? EditDragOverlay }).first,
              let idx = overlay.itemViews.firstIndex(where: { $0 === self }) else { return }
        overlay.beginInteractiveReorder(startIndex: idx, startEvent: event)
    }

    // 非アクティブ状態でのクリック（左右両方）を活性化消費せずそのままビューに届ける。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Click

    @objc private func handleLeftClick() {
        // 編集モード中はドラッグオーバーレイが処理するため左クリックは無視
        guard !isEditMode else { return }
        flashAndCall(onPress)
    }

    /// NSPanel の sendEvent 経由でなく AppKit の標準ディスパッチで届く。
    /// OverflowPanel は NSPanel(.borderless) のため rightMouseDown は
    /// NSView 層まで確実に伝達される（nonactivatingPanel でないため）。
    override func rightMouseDown(with event: NSEvent) {
        triggerRightPress()
    }

    func triggerRightPress() {
        if isEditMode {
            // 編集モード中は flash しない。
            // flashAndCall のアニメーション途中でカテゴリメニューが開くと、
            // 完了ハンドラが呼ばれず hover ハイライト（白 15%）が残留するため。
            layer?.backgroundColor = NSColor.clear.cgColor  // hover bg をリセット
            Self.hoverWindow?.orderOut(nil)                  // ツールチップも閉じる
            onRightPress()
        } else {
            flashAndCall(onRightPress)
        }
    }

    private func flashAndCall(_ action: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.06
            animator().layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        }) { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.06
                self?.animator().layer?.backgroundColor = NSColor.clear.cgColor
            }
            action()
        }
    }
}

// MARK: - OverflowSettingsViewController ──────────────────────────────────────
//
// ギアボタンをタップすると表示される NSPopover のコンテンツ VC。
// 3 セクション構成（下から上へ積み上げてレイアウト）:
//   Section 1: 表示モード  — NSSegmentedControl (フラット / カテゴリ)
//   Section 2: アイコン幅  — NSSlider 32–48pt + 現在値ラベル
//   Section 3: パネル動作  — "クリック後にパネルを閉じる" チェックボックス

final class OverflowSettingsViewController: NSViewController {

    var onDisplayModeChange:     ((OverflowDisplayMode) -> Void)?
    var onIconWidthChange:       ((CGFloat) -> Void)?
    var onPanelOpacityChange:    ((Double) -> Void)?
    var onBlendCorrectionChange: (() -> Void)?

    /// 現在の編集モード状態（OverflowPanelContent が popover 表示前に設定する）
    var currentEditMode = false
    /// 編集モードボタンが押されたときのコールバック
    var onEditModeToggle: (() -> Void)?

    private var editModeButton: NSButton?

    private var settings = DataStore.shared.overflowSettings

    private let modeSegment       = NSSegmentedControl()
    private let widthSlider       = NSSlider()
    private let widthValueLabel   = NSTextField(labelWithString: "")
    private let opacitySlider     = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let brightSlider      = NSSlider()
    private let brightLabel       = NSTextField(labelWithString: "")
    private let satSlider         = NSSlider()
    private let satLabel          = NSTextField(labelWithString: "")
    private let dismissCheck      = NSButton(checkboxWithTitle: L("Close panel on click",
                                                                   "クリック後にパネルを閉じる"),
                                             target: nil, action: nil)

    static let popoverWidth: CGFloat = 220

    // MARK: View lifecycle

    override func loadView() {
        // macOS 標準ポップオーバーと同一のマテリアルを使用
        let fx = NSVisualEffectView()
        fx.material     = .popover
        fx.blendingMode = .behindWindow
        fx.state        = .active
        view = fx
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    // MARK: UI construction (bottom-up)

    private func buildUI() {
        let pad:      CGFloat = 12
        let contentW: CGFloat = Self.popoverWidth - pad * 2
        var y:        CGFloat = pad

        // ── Section 3: パネル動作 ─────────────────────────────────────────

        dismissCheck.state  = settings.dismissOnClick ? .on : .off
        dismissCheck.target = self
        dismissCheck.action = #selector(dismissCheckChanged)
        dismissCheck.frame  = NSRect(x: pad, y: y, width: contentW, height: 18)
        view.addSubview(dismissCheck)
        y += 18 + 10

        view.addSubview(makeSeparator(y: y))
        y += 1 + 8

        view.addSubview(makeSectionHeader(L("Panel Behavior", "パネル動作"), x: pad, y: y))
        y += 14 + 10

        // ── Section 2: 表示（透過度 + アイコン幅）────────────────────────

        // 透過度スライダー
        let opacityPct = Int(settings.panelOpacity * 100)
        opacityValueLabel.stringValue = "\(opacityPct)%"
        opacityValueLabel.font        = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityValueLabel.textColor   = .secondaryLabelColor
        opacityValueLabel.alignment   = .right
        opacityValueLabel.frame       = NSRect(x: pad + contentW - 36, y: y + 2,
                                               width: 36, height: 16)
        view.addSubview(opacityValueLabel)

        opacitySlider.minValue     = 0.0   // 0% = 完全透明（背景なし）
        opacitySlider.maxValue     = 1.0   // 100% = メニューバー色で完全不透明（デフォルト）
        opacitySlider.doubleValue  = settings.panelOpacity
        opacitySlider.isContinuous = true
        opacitySlider.target       = self
        opacitySlider.action       = #selector(opacitySliderChanged)
        opacitySlider.frame = NSRect(x: pad, y: y, width: contentW - 42, height: 20)
        view.addSubview(opacitySlider)
        y += 20 + 3

        view.addSubview(makeSubLabel(L("Background Opacity", "背景の不透明度"), x: pad, y: y))
        y += 11 + 10

        // ── なじみ補正 (明度・彩度) ────────────────────────────────────────

        // 彩度補正スライダー
        satLabel.stringValue = String(format: "×%.2f", settings.blendSaturation)
        satLabel.font        = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        satLabel.textColor   = .secondaryLabelColor
        satLabel.alignment   = .right
        satLabel.frame       = NSRect(x: pad + contentW - 44, y: y + 2, width: 44, height: 16)
        view.addSubview(satLabel)

        satSlider.minValue                = 0.70   // 0.70, 0.75, …, 1.10 (9刻み)
        satSlider.maxValue                = 1.10
        satSlider.numberOfTickMarks       = 9
        satSlider.allowsTickMarkValuesOnly = true
        satSlider.doubleValue             = settings.blendSaturation
        satSlider.isContinuous            = true
        satSlider.target                  = self
        satSlider.action                  = #selector(satSliderChanged)
        satSlider.frame = NSRect(x: pad, y: y, width: contentW - 50, height: 20)
        view.addSubview(satSlider)
        y += 20 + 3

        view.addSubview(makeSubLabel(L("Saturation", "彩度補正"), x: pad, y: y))
        y += 11 + 6

        // 明度補正スライダー
        brightLabel.stringValue = String(format: "×%.2f", settings.blendBrightness)
        brightLabel.font        = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        brightLabel.textColor   = .secondaryLabelColor
        brightLabel.alignment   = .right
        brightLabel.frame       = NSRect(x: pad + contentW - 44, y: y + 2, width: 44, height: 16)
        view.addSubview(brightLabel)

        brightSlider.minValue                = 0.80   // 0.80, 0.85, …, 1.20 (9刻み)
        brightSlider.maxValue                = 1.20
        brightSlider.numberOfTickMarks       = 9
        brightSlider.allowsTickMarkValuesOnly = true
        brightSlider.doubleValue             = settings.blendBrightness
        brightSlider.isContinuous            = true
        brightSlider.target                  = self
        brightSlider.action                  = #selector(brightSliderChanged)
        brightSlider.frame = NSRect(x: pad, y: y, width: contentW - 50, height: 20)
        view.addSubview(brightSlider)
        y += 20 + 3

        view.addSubview(makeSubLabel(L("Brightness", "明度補正"), x: pad, y: y))
        y += 11 + 6

        view.addSubview(makeSectionHeader(L("Blend", "なじみ補正"), x: pad, y: y))
        y += 14 + 8

        // アイコン幅スライダー
        widthValueLabel.stringValue = "\(Int(settings.iconWidth))pt"
        widthValueLabel.font        = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthValueLabel.textColor   = .secondaryLabelColor
        widthValueLabel.alignment   = .right
        widthValueLabel.frame       = NSRect(x: pad + contentW - 36, y: y + 2,
                                             width: 36, height: 16)
        view.addSubview(widthValueLabel)

        widthSlider.minValue              = 32
        widthSlider.maxValue              = 48
        widthSlider.doubleValue           = Double(settings.iconWidth)
        widthSlider.numberOfTickMarks     = 9   // 32,34,36,38,40,42,44,46,48
        widthSlider.allowsTickMarkValuesOnly = true
        widthSlider.target                = self
        widthSlider.action                = #selector(widthSliderChanged)
        widthSlider.frame = NSRect(x: pad, y: y, width: contentW - 42, height: 20)
        view.addSubview(widthSlider)
        y += 20 + 3

        view.addSubview(makeSubLabel(L("Icon Width", "アイコン幅"), x: pad, y: y))
        y += 11 + 10

        view.addSubview(makeSeparator(y: y))
        y += 1 + 8

        view.addSubview(makeSectionHeader(L("Display", "表示"), x: pad, y: y))
        y += 14 + 10

        // ── Section 1: 表示モード ─────────────────────────────────────────

        modeSegment.segmentCount    = 2
        modeSegment.setLabel(L("Flat",     "フラット"), forSegment: 0)
        modeSegment.setLabel(L("Category", "カテゴリ"), forSegment: 1)
        modeSegment.selectedSegment = settings.displayMode == .flat ? 0 : 1
        modeSegment.segmentStyle    = .texturedRounded
        modeSegment.target          = self
        modeSegment.action          = #selector(modeSegmentChanged)
        modeSegment.frame = NSRect(x: pad, y: y, width: contentW, height: 24)
        view.addSubview(modeSegment)
        y += 24 + pad

        view.addSubview(makeSeparator(y: y))
        y += 1 + 8

        // ── Language ──────────────────────────────────────────────────────
        let langSegment = NSSegmentedControl()
        langSegment.segmentCount    = 2
        langSegment.setLabel("English",  forSegment: 0)
        langSegment.setLabel("日本語",   forSegment: 1)
        langSegment.selectedSegment = LanguageManager.shared.isEnglish ? 0 : 1
        langSegment.segmentStyle    = .texturedRounded
        langSegment.target          = self
        langSegment.action          = #selector(langSegmentChanged)
        langSegment.frame = NSRect(x: pad, y: y, width: contentW, height: 24)
        view.addSubview(langSegment)
        y += 24 + 3

        view.addSubview(makeSectionHeader("Language", x: pad, y: y))
        y += 14 + pad

        view.addSubview(makeSeparator(y: y))
        y += 1 + 8

        // ── Edit Mode button ──────────────────────────────────────────────
        let editTitle = currentEditMode ? L("✏️ Editing", "✏️ 編集中")
                                        : L("✏️ Edit Mode", "✏️ 編集モード")
        let btn = NSButton(title: editTitle, target: self, action: #selector(editModeTapped))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: pad, y: y, width: contentW, height: 24)
        view.addSubview(btn)
        editModeButton = btn
        y += 24 + pad

        // ── 全体サイズを確定 ──────────────────────────────────────────────
        view.frame = NSRect(x: 0, y: 0, width: Self.popoverWidth, height: y)
    }

    // MARK: Actions

    @objc private func langSegmentChanged(_ sender: NSSegmentedControl) {
        let lang: AppLanguage = sender.selectedSegment == 0 ? .english : .japanese
        LanguageManager.shared.current = lang
        // Close and reopen the popover so labels refresh with the new language
        view.window?.close()
    }

    @objc private func editModeTapped() {
        // onEditModeToggle の内部で vc.currentEditMode が正しく更新される。
        // ここで toggle() を重ねると二重トグルになるため、呼ばない。
        onEditModeToggle?()
        // コールバック完了後、currentEditMode は最新値になっているのでそのままタイトルに反映する。
        editModeButton?.title = currentEditMode ? L("✏️ Editing", "✏️ 編集中")
                                                : L("✏️ Edit Mode", "✏️ 編集モード")
    }

    @objc private func modeSegmentChanged() {
        let newMode: OverflowDisplayMode = modeSegment.selectedSegment == 0 ? .flat : .category
        settings.displayMode = newMode
        DataStore.shared.overflowSettings = settings
        onDisplayModeChange?(newMode)
    }

    @objc private func widthSliderChanged() {
        let w = CGFloat(widthSlider.doubleValue)
        widthValueLabel.stringValue = "\(Int(w))pt"
        settings.iconWidth = w
        DataStore.shared.overflowSettings = settings
        onIconWidthChange?(w)
    }

    @objc private func opacitySliderChanged() {
        let v = opacitySlider.doubleValue
        opacityValueLabel.stringValue = "\(Int(v * 100))%"
        settings.panelOpacity = v
        DataStore.shared.overflowSettings = settings
        onPanelOpacityChange?(v)
    }

    @objc private func brightSliderChanged() {
        let v = brightSlider.doubleValue
        brightLabel.stringValue = String(format: "×%.2f", v)
        settings.blendBrightness = v
        DataStore.shared.overflowSettings = settings
        onBlendCorrectionChange?()
    }

    @objc private func satSliderChanged() {
        let v = satSlider.doubleValue
        satLabel.stringValue = String(format: "×%.2f", v)
        settings.blendSaturation = v
        DataStore.shared.overflowSettings = settings
        onBlendCorrectionChange?()
    }

    @objc private func dismissCheckChanged() {
        settings.dismissOnClick = (dismissCheck.state == .on)
        DataStore.shared.overflowSettings = settings
    }

    // MARK: Helpers

    private func makeSectionHeader(_ title: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: title)
        lbl.font      = .systemFont(ofSize: 11, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        lbl.frame     = NSRect(x: x, y: y, width: 160, height: 14)
        return lbl
    }

    /// スライダーの下に表示する小さいラベル
    private func makeSubLabel(_ title: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: title)
        lbl.font      = .systemFont(ofSize: 10)
        lbl.textColor = .tertiaryLabelColor
        lbl.frame     = NSRect(x: x, y: y, width: 160, height: 11)
        return lbl
    }

    private func makeSeparator(y: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.frame   = NSRect(x: 0, y: y, width: Self.popoverWidth, height: 1)
        return box
    }
}

// MARK: - MenuBarGradientSampler ──────────────────────────────────────────────
//
// メニューバー領域を「幅全体×1px」の CGImage としてキャプチャするユーティリティ。
//
// アルゴリズム:
//   1. CGWindowListCreateImage でメニューバー全体矩形をキャプチャ
//   2. 中央行（height/2）の 1px を cropping で切り出す
//      → 横方向の色変化を完全に保持したグラデーション行
//   3. CIColorControls で明度・彩度補正を適用（オプション）
//
// 描画側:
//   layer.contents にこの 1px 画像をセット。
//   layer.contentsRect でパネルの画面 X 位置に対応するスライスを指定。
//   layer.contentsGravity = .resize で縦方向にストレッチ。
//   → 水平方向はメニューバーの各位置と完全一致、縦は均一ストライプ。

// MARK: - FallbackMenuActionHandler

/// フォールバックコンテキストメニューのアクションを処理する Obj-C ターゲット。
final class FallbackMenuActionHandler: NSObject {
    static let shared = FallbackMenuActionHandler()
    private override init() {}

    /// Toggle（左クリック相当）: AXPress を実行する
    @objc func handleToggle(_ sender: NSMenuItem) {
        guard let element = sender.representedObject else { return }
        AXUIElementPerformAction(element as! AXUIElement, kAXPressAction as CFString)
    }

    /// Quit: 対象アプリを終了する
    @objc func handleQuit(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        // アプリ終了後、少し待ってからパネルを即座に再スキャンしてアイコンを消す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            OverflowStatusManager.shared.forceRefresh()
        }
    }
}

// MARK: - DebugLog ────────────────────────────────────────────────────────────
#if DEBUG
/// /tmp/MenuBarDockX_debug.log にタイムスタンプ付きで追記する。
/// スレッドセーフ（DispatchQueue でシリアル書き込み）。
func DebugLog(_ message: String) {
    let line = "[\(Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2))))] \(message)\n"
    DebugLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: DebugLogPath) {
            if let fh = FileHandle(forWritingAtPath: DebugLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: DebugLogPath), options: .atomic)
        }
    }
}
private let DebugLogPath  = "/tmp/MenuBarDockX_debug.log"
private let DebugLogQueue = DispatchQueue(label: "com.MenuBarDockX.debugLog")

/// /tmp/mbdx_click.log にクリック診断ログを追記する。
/// DebugLog とは別ファイルに分けることで絞り込みが容易になる。
func ClickLog(_ message: String) {
    let ts   = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    let line = "[\(ts)] \(message)\n"
    DebugLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/mbdx_click.log"
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif

enum MenuBarGradientSampler {

    // MARK: - CIContext（使い回しでパフォーマンスを確保）

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Raw キャプチャ

    /// メニューバー全体をキャプチャし、中央行の 1px CGImage を返す（補正なし）。
    /// - スクリーン録画許可がなければ nil。
    /// - バックグラウンドスレッドから呼ぶこと。
    static func sampleRaw() -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let screen = NSScreen.screens.first else { return nil }

        let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        guard menuBarH > 0 else { return nil }

        // CG座標系: y=0 = 画面最上部（メニューバー）
        let cgRect = CGRect(x: 0, y: 0,
                            width: screen.frame.width,
                            height: menuBarH)
        guard let full = CGWindowListCreateImage(
            cgRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution
        ) else { return nil }

        // メニューバー中央行を 1px に切り出す
        // CG 座標の y=0 は画像の上端（cropping の y は画像左下原点）
        // → height-1 を引いた y が画像上端。中央は height/2 あたり。
        let cy = full.height / 2
        return full.cropping(to: CGRect(x: 0, y: cy, width: full.width, height: 1))
    }

    // MARK: - 補正適用

    /// CIColorControls で明度・彩度補正を適用した CGImage を返す。
    ///   brightness: 1.0 = 変化なし、0.8 = 20% 暗く、1.2 = 20% 明るく
    ///   saturation: 1.0 = 変化なし、0.7 = 彩度 70%、1.1 = 彩度 110%
    // MARK: - 方式B：ガウスぼかし + 色補正（推奨）

    /// デフォルトのガウスぼかし半径（物理ピクセル単位）。
    /// Retina (2x) では1px行画像が ~2880px 幅になるため、120pt 相当の平滑化には 240px 程度が必要。
    /// 大きいほど縞が消えるが端部の色がにじむ。
    static let defaultBlurRadius: Double = 240

    /// 方式B: ガウスぼかし → 明度/彩度補正 の順に CIFilter を適用して返す。
    ///
    /// - blurRadius > 0: 横方向の色変化を平滑化し「虹色縞」を解消する。
    ///   CIGaussianBlur はエクステントを広げるため、元のサイズに cropped して戻す。
    /// - brightness/saturation: CIColorControls で補正（1.0 = 変化なし）。
    static func processImage(
        _ image:      CGImage,
        blurRadius:   Double = defaultBlurRadius,
        brightness:   Double = 1.0,
        saturation:   Double = 1.0
    ) -> CGImage? {
        let originalExtent = CIImage(cgImage: image).extent
        var ci = CIImage(cgImage: image)

        // ── ガウスぼかし ─────────────────────────────────────────────────
        if blurRadius > 0,
           let blur = CIFilter(name: "CIGaussianBlur") {
            // clampedToExtent() でエッジ色を無限に引き伸ばす → 端部の暗化アーティファクトを防止
            blur.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(blurRadius,           forKey: kCIInputRadiusKey)
            if let out = blur.outputImage {
                // ぼかしによるエクステント拡大を元サイズにクロップ
                ci = out.cropped(to: originalExtent)
            }
        }

        // ── 明度・彩度補正 ───────────────────────────────────────────────
        if brightness != 1.0 || saturation != 1.0,
           let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(ci,                forKey: kCIInputImageKey)
            cc.setValue(Float(brightness - 1), forKey: kCIInputBrightnessKey) // −1…+1
            cc.setValue(Float(saturation),     forKey: kCIInputSaturationKey) //  0…+2
            if let out = cc.outputImage { ci = out }
        }

        return ciContext.createCGImage(ci, from: originalExtent)
    }

}

// MARK: - DebugColorBarWindow ─────────────────────────────────────────────────
#if DEBUG
/// サンプリング色をメニューバー直下に 5pt バーとして表示するデバッグウィンドウ。
///
/// 目的:
///   「実際にサンプリングできている色」と「メニューバーの見た目」を
///   NSVisualEffectView・solidOverlay などの影響なしに目視比較するため。
///
/// 見方:
///   - バーが最初に赤く光る → show() が呼ばれた証拠
///   - バーとメニューバーが同色 → サンプリング自体は正しい（問題は別の層）
///   - バーとメニューバーがズレている → cgRect やキャプチャの問題
///   - バーが赤いまま → サンプリングが1回も成功していない（権限 or cgImage nil）

final class DebugColorBarWindow {
    static let shared = DebugColorBarWindow()

    private var window: NSWindow?
    private var colorView: NSView?

    private init() {}

    func show() {
        guard window == nil, let screen = NSScreen.screens.first else { return }
        let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        let barH: CGFloat = 5
        // Cocoa 座標: メニューバー直下 = maxY - menuBarH - barH
        let barFrame = NSRect(
            x:      screen.frame.minX,
            y:      screen.frame.maxY - menuBarH - barH,
            width:  screen.frame.width,
            height: barH
        )
        let win = NSPanel(
            contentRect: barFrame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        win.isOpaque           = true
        win.hasShadow          = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        // 初期色は赤 — この色のまま残っていればサンプリングが1回も成功していない
        view.layer?.backgroundColor = NSColor.systemRed.cgColor
        win.contentView = view
        win.orderFront(nil)

        DebugLog("[DebugColorBarWindow] 表示: frame=\(NSStringFromRect(barFrame)) (メニューバー直下 \(Int(barH))pt)")

        self.window    = win
        self.colorView = view
    }

    /// サンプリングしたグラデーション画像をデバッグバーに反映する。
    func updateImage(_ image: CGImage?) {
        guard let layer = colorView?.layer else { return }
        layer.contents        = image
        layer.contentsGravity = .resize   // 縦 5pt に伸張して表示
    }

    func hide() {
        DebugLog("[DebugColorBarWindow] 非表示")
        window?.orderOut(nil)
        window    = nil
        colorView = nil
    }
}
#endif

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
