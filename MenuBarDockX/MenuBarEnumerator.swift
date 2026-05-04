import AppKit
import ApplicationServices
import CoreImage

/// Enumerates menu bar STATUS ITEMS (right-side icons).
///
/// Strategy:
///  1. Try "AXExtrasMenuBar" (private attribute) — this is the actual right-side
///     status-item bar on macOS 12+.
///  2. Fall back to kAXMenuBarAttribute and filter by horizontal position
///     (> 55 % of screen width) to catch any legacy sources.
///  3. Explicitly query com.apple.SystemUIServer which still owns Siri.
final class MenuBarEnumerator {

    private var knownIDs: [String: UUID] = [:]

    // MARK: - Public API

    /// Returns items that are in AXExtrasMenuBar but have no valid screen position —
    /// i.e., items hidden because the macOS notch blocks them.
    /// Call this from OverflowStatusManager (background thread OK).
    ///
    /// 隠れ判定の 2 パターン:
    ///   A. pos.x <= 0 → macOS がアイテムを可視域外に追い出した
    ///      旧実装は (pos.x==0 && width==0) のみを捕捉していたが、
    ///      Stats など一部アプリは「pos.x=0 だが width > 0」で返すため
    ///      pos.x <= 0 全体を捕捉するよう拡張。
    ///   B. pos.x がノッチゾーン内 (0 < pos.x < notchInfo.rightEdgeX) →
    ///      物理的にノッチに隠れているが AX 上は有効座標を保持している。
    ///
    /// 重複排除の 2 レイヤー:
    ///   1. stableKey (bundleID + description) — 通常のデドゥプ
    ///   2. SF Symbol キー (bundleID + symbol) — Battery 英/日語バリアント対策
    /// ノッチ/画面外に隠れているメニューバーアイテムを列挙する。
    /// - Parameter dtos: DataStore から読み込んだ保存済み DTO。
    ///   stableKey で照合し、ID・categoryID・sortOrder を復元する。
    ///   nil の場合は既存の knownIDs のみを使用する（後方互換）。
    func enumerateHiddenItems(merging dtos: [MenuBarItemDTO] = []) -> [MenuBarItem] {
        guard AXIsProcessTrusted() else { return [] }

        // DTO を stableKey でインデックス化する（ID・categoryID の復元に使用）
        var dtoByKey: [String: MenuBarItemDTO] = [:]
        for dto in dtos {
            let key = stableKey(bundleID: dto.bundleID,
                                description: dto.axDescription,
                                appName: dto.appName)
            dtoByKey[key] = dto
        }

        let notchInfo: NotchInfo
        #if DEBUG
        notchInfo = DebugSettings.shared.makeSimulatedNotchInfo() ?? NotchDetector.detect()
        #else
        notchInfo = NotchDetector.detect()
        #endif

        var results:  [MenuBarItem] = []
        var sortIndex = 0
        var seen      = Set<String>()   // stableKey (bundleID|desc) 重複排除
        var seenSym   = Set<String>()   // SF Symbol キー重複排除 (Battery 二重対策)
        // description が空の非 Apple アイテム (Stats 等) は同一 bundleID から複数存在しうる。
        // per-bundleID カウンタで各アイテムに固有のサフィックスを付与し、重複排除を防ぐ。
        var emptyDescCount: [String: Int] = [:]

        var logLines: [String] = [
            "[enumerateHiddenItems] notch=\(notchInfo.hasNotch) rightEdgeX=\(Int(notchInfo.rightEdgeX))"
        ]

        // ── Candidate processes ─────────────────────────────────────────────
        var candidates: [NSRunningApplication] = []
        for bid in ["com.apple.controlcenter", "com.apple.SystemUIServer"] {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bid).first {
                candidates.append(app)
            }
        }
        var seenBID = Set<String>(candidates.compactMap(\.bundleIdentifier))
        for app in NSWorkspace.shared.runningApplications {
            let k = app.bundleIdentifier ?? "\(app.processIdentifier)"
            guard seenBID.insert(k).inserted else { continue }
            candidates.append(app)
        }

        let myBundleID = Bundle.main.bundleIdentifier ?? ""

        for app in candidates {
            let pid     = app.processIdentifier
            let bid     = app.bundleIdentifier
            let appName = app.localizedName ?? (bid ?? "\(pid)")
            let axApp   = AXUIElementCreateApplication(pid)

            if bid == myBundleID { continue }

            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
                  CFGetTypeID(extrasRef!) == AXUIElementGetTypeID() else { continue }

            let extrasBar = extrasRef as! AXUIElement
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                extrasBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }

            logLines.append("[\(appName)] extras children=\(children.count)")

            for element in children {
                let pos   = axPosition(element)
                let size  = axSize(element)
                let desc  = axDescription(element)
                let title = axTitle(element)

                // ── 隠れアイテム判定 ─────────────────────────────────────────
                //
                // Pattern A: pos.x <= 0
                //   status item の左端が 0 以下 = macOS が可視域外に追い出した。
                //   「pos.x==0 && width==0」のみを見ていた旧実装では
                //   Stats 等 (pos.x=0, width>0) を取り逃がしていたため拡張。
                let isHiddenLeft = pos.x <= 0

                // Pattern B: ノッチゾーン内 (有効座標だがノッチに隠されている)
                //   pos.x が 0 より大きく notchInfo.rightEdgeX より小さい
                //   → アイテムの左端がノッチ内に入っている
                let isInNotchZone = notchInfo.hasNotch
                    && pos.x > 0
                    && pos.x < notchInfo.rightEdgeX

                let isHidden = isHiddenLeft || isInNotchZone

                logLines.append(
                    "  [\(appName)] x=\(Int(pos.x)) w=\(Int(size.width)) desc='\(desc)' title='\(title)'" +
                    " hiddenL=\(isHiddenLeft) notch=\(isInNotchZone)"
                )

                guard isHidden else { continue }

                // Apple system item で description が空 → ユーザーが意図的に
                // 非表示にした設定コントロール（overflow ではない）
                let isApple = (bid ?? "").hasPrefix("com.apple.")
                guard !desc.isEmpty || !title.isEmpty || !isApple else { continue }

                // desc が空のとき AXTitle を description 代替として使用する。
                // Stats 等は desc が空でも title が "CPU", "Network" 等で識別可能な場合がある。
                let effectiveDesc = desc.isEmpty ? title : desc

                // ── 重複排除 ─────────────────────────────────────────────────
                // Layer 1: stableKey (bundleID + description)
                // effectiveDesc が空の非 Apple アイテム (Stats 等) は同一 bundleID から
                // 複数存在しうる。同一キーでまとめると 1 件しか表示されないため、
                // 空のときは per-bundleID インデックスをサフィックスに付加する。
                let key: String
                if effectiveDesc.isEmpty {
                    let appKey = bid ?? appName
                    let idx = emptyDescCount[appKey, default: 0]
                    emptyDescCount[appKey] = idx + 1
                    key = stableKey(bundleID: bid, description: "|empty:\(idx)", appName: appName)
                } else {
                    key = stableKey(bundleID: bid, description: effectiveDesc, appName: appName)
                }
                guard seen.insert(key).inserted else { continue }

                // Layer 2: SF Symbol キー (Battery 英語/日本語バリアント対策)
                // sfSymbol() が non-nil = 既知のシステムアイコン。
                // 同一 symbol が同 bundleID から 2 回現れたら 2 枚目を除去する。
                if let sym = sfSymbol(for: effectiveDesc) {
                    let symKey = "\(bid ?? appName)|\(sym)"
                    guard seenSym.insert(symKey).inserted else {
                        logLines.append("    -> dup by symbol '\(sym)', skipped")
                        continue
                    }
                }

                // ── アイテム生成 ─────────────────────────────────────────────
                // DTO が存在する場合は保存済みの ID を優先する（再起動後もIDを安定させる）。
                // knownIDs は同一セッション内での安定化に使用する。
                let id: UUID
                if let dto = dtoByKey[key]    { id = dto.id }
                else if let e = knownIDs[key] { id = e }
                else                          { let u = UUID(); knownIDs[key] = u; id = u }

                var item = MenuBarItem(
                    id: id,
                    bundleID: bid,
                    appName: appName,
                    axDescription: effectiveDesc,
                    frame: .zero,
                    isSystemItem: isSystemItem(bundleID: bid,
                                               execPath: app.executableURL?.path ?? ""),
                    categoryID: dtoByKey[key]?.categoryID,
                    sortOrder: dtoByKey[key]?.sortOrder ?? sortIndex
                )
                item.isHidden  = true
                item.image     = resolveImage(element: element, description: effectiveDesc, app: app)
                item.axElement = element

                results.append(item)
                sortIndex += 1
                logLines.append("    -> ACCEPTED '\(appName)/\(desc)'")
            }
        }

        // デバッグログ（enumerate の /tmp/mbdx_items.log とは別ファイル）
        try? logLines.joined(separator: "\n")
            .write(toFile: "/tmp/mbdx_hidden.log", atomically: true, encoding: .utf8)

        return results
    }

    func enumerate(merging existing: [MenuBarItemDTO]) -> [MenuBarItem] {
        var dtoByKey: [String: MenuBarItemDTO] = [:]
        for dto in existing {
            let key = stableKey(bundleID: dto.bundleID,
                                description: dto.axDescription,
                                appName: dto.appName)
            dtoByKey[key] = dto
        }

        let threshold = statusThreshold()
        var logLines: [String] = [
            "AX=\(AXIsProcessTrusted())  screen=\(NSScreen.main?.frame.width ?? 0)  threshold=\(Int(threshold))"
        ]

        var results: [MenuBarItem] = []
        var sortIndex = 0
        var seen = Set<String>()   // deduplicate by stableKey

        // ── Candidate processes ───────────────────────────────────────────────
        var candidates: [NSRunningApplication] = []

        // 1. System status item managers (always query these explicitly)
        for bid in ["com.apple.controlcenter",
                    "com.apple.SystemUIServer",
                    "com.apple.notificationcenterui"] {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bid).first {
                candidates.append(app)
            }
        }

        // 2. All other running apps (deduped by bundle ID)
        var seenBID = Set<String>(candidates.compactMap(\.bundleIdentifier))
        for app in NSWorkspace.shared.runningApplications {
            let key = app.bundleIdentifier ?? "\(app.processIdentifier)"
            guard seenBID.insert(key).inserted else { continue }
            candidates.append(app)
        }

        // ── Query each candidate ──────────────────────────────────────────────
        for app in candidates {
            let appItems = queryMenuBar(
                of: app,
                threshold: threshold,
                dtoByKey: dtoByKey,
                sortIndex: &sortIndex,
                seen: &seen,
                log: &logLines
            )
            results.append(contentsOf: appItems)
        }

        try? logLines.joined(separator: "\n")
            .write(toFile: "/tmp/mbdx_items.log", atomically: true, encoding: .utf8)

        return results.sorted { $0.sortOrder < $1.sortOrder }
    }

    func pressItem(_ item: MenuBarItem) {
        guard let element = item.axElement else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// Finds the JetBrains Toolbox status item in AXExtrasMenuBar, if running.
    /// Returns nil when Toolbox is not running or has no AX-accessible element.
    /// Safe to call from a background thread.
    func findToolboxItem() -> MenuBarItem? {
        let apps = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.jetbrains.toolbox")
        guard let app = apps.first else { return nil }

        let pid   = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
              CFGetTypeID(extrasRef!) == AXUIElementGetTypeID() else { return nil }

        let extrasBar = extrasRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            extrasBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              let element  = children.first else { return nil }

        let desc     = axDescription(element)
        let key      = stableKey(bundleID: "com.jetbrains.toolbox",
                                 description: desc,
                                 appName: "JetBrains Toolbox")
        let id       = knownIDs[key] ?? {
            let u = UUID(); knownIDs[key] = u; return u
        }()

        var item = MenuBarItem(
            id: id,
            bundleID: "com.jetbrains.toolbox",
            appName: "JetBrains Toolbox",
            axDescription: desc.isEmpty ? "JetBrains Toolbox" : desc,
            frame: .zero,
            isSystemItem: false,
            categoryID: nil,
            sortOrder: -1          // pin to front
        )
        item.isHidden  = true
        item.image     = app.icon
        item.axElement = element
        return item
    }

    // MARK: - Per-process query

    private func queryMenuBar(of app: NSRunningApplication,
                              threshold: CGFloat,
                              dtoByKey: [String: MenuBarItemDTO],
                              sortIndex: inout Int,
                              seen: inout Set<String>,
                              log: inout [String]) -> [MenuBarItem] {
        let pid      = app.processIdentifier
        let axApp    = AXUIElementCreateApplication(pid)

        // ── 1. Try AXExtrasMenuBar (right-side status items) ─────────────────
        var extrasItems = queryExtrasMenuBar(axApp: axApp, app: app,
                                             dtoByKey: dtoByKey,
                                             sortIndex: &sortIndex,
                                             seen: &seen,
                                             log: &log)

        // ── 2. Fallback: standard menu bar filtered by position ───────────────
        let standardItems = queryStandardMenuBar(axApp: axApp, app: app,
                                                  threshold: threshold,
                                                  dtoByKey: dtoByKey,
                                                  sortIndex: &sortIndex,
                                                  seen: &seen,
                                                  log: &log)

        extrasItems.append(contentsOf: standardItems)
        return extrasItems
    }

    // MARK: - AXExtrasMenuBar query

    private func queryExtrasMenuBar(axApp: AXUIElement,
                                    app: NSRunningApplication,
                                    dtoByKey: [String: MenuBarItemDTO],
                                    sortIndex: inout Int,
                                    seen: inout Set<String>,
                                    log: inout [String]) -> [MenuBarItem] {
        let bundleID = app.bundleIdentifier
        let appName  = app.localizedName ?? (bundleID ?? "\(app.processIdentifier)")

        var extrasRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            axApp, "AXExtrasMenuBar" as CFString, &extrasRef)

        guard err == .success,
              CFGetTypeID(extrasRef!) == AXUIElementGetTypeID() else {
            if err != .attributeUnsupported && err != .noValue {
                log.append("[\(appName)] extrasMenuBar err=\(err.rawValue)")
            }
            return []
        }

        let extrasBar = extrasRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            extrasBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            log.append("[\(appName)] extrasMenuBar no children")
            return []
        }

        log.append("[\(appName)] extrasMenuBar children=\(children.count)")

        var items: [MenuBarItem] = []
        let isSystem = isSystemItem(bundleID: bundleID,
                                    execPath: app.executableURL?.path ?? "")

        for element in children {
            let pos    = axPosition(element)
            let size   = axSize(element)
            let desc   = axDescription(element)
            let role   = axRole(element)

            log.append("  [extras/\(appName)] role=\(role) x=\(Int(pos.x)) w=\(Int(size.width)) '\(desc)'")

            // Accept items that have a meaningful description OR a valid position
            let hasValidPos  = pos.x > 0 || size.width > 0
            let hasValidDesc = !desc.isEmpty
            guard hasValidPos || hasValidDesc else { continue }

            let key = stableKey(bundleID: bundleID, description: desc, appName: appName)
            guard seen.insert(key).inserted else { continue }

            let id: UUID
            if let dto = dtoByKey[key]    { id = dto.id }
            else if let e = knownIDs[key] { id = e }
            else { id = UUID(); knownIDs[key] = id }

            let frame    = CGRect(origin: pos, size: size)
            let rawImage = resolveImage(element: element, description: desc, app: app)

            var item = MenuBarItem(
                id: id,
                bundleID: bundleID,
                appName: appName,
                axDescription: desc,
                frame: frame,
                isSystemItem: isSystem,
                categoryID: dtoByKey[key]?.categoryID,
                sortOrder: dtoByKey[key]?.sortOrder ?? sortIndex
            )
            item.image     = rawImage.map { processImage($0) }
            item.axElement = element

            items.append(item)
            sortIndex += 1
        }

        return items
    }

    // MARK: - Standard menu bar query (position-filtered fallback)

    private func queryStandardMenuBar(axApp: AXUIElement,
                                      app: NSRunningApplication,
                                      threshold: CGFloat,
                                      dtoByKey: [String: MenuBarItemDTO],
                                      sortIndex: inout Int,
                                      seen: inout Set<String>,
                                      log: inout [String]) -> [MenuBarItem] {
        let bundleID = app.bundleIdentifier
        let appName  = app.localizedName ?? (bundleID ?? "\(app.processIdentifier)")

        var menuBarRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            axApp, kAXMenuBarAttribute as CFString, &menuBarRef)
        guard err == .success,
              CFGetTypeID(menuBarRef!) == AXUIElementGetTypeID() else {
            if err != .attributeUnsupported && err != .noValue && err.rawValue != -25212 {
                log.append("[\(appName)] menuBar err=\(err.rawValue)")
            }
            return []
        }

        let menuBar = menuBarRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }

        var items: [MenuBarItem] = []
        let isSystem = isSystemItem(bundleID: bundleID,
                                    execPath: app.executableURL?.path ?? "")

        for element in children {
            let pos  = axPosition(element)
            let size = axSize(element)
            let desc = axDescription(element)

            log.append("  [\(appName)] x=\(Int(pos.x)) w=\(Int(size.width)) '\(desc)'")

            guard pos.x >= threshold, size.width > 0, size.height > 0 else { continue }

            let key = stableKey(bundleID: bundleID, description: desc, appName: appName)
            guard seen.insert(key).inserted else { continue }

            let id: UUID
            if let dto = dtoByKey[key]    { id = dto.id }
            else if let e = knownIDs[key] { id = e }
            else { id = UUID(); knownIDs[key] = id }

            let frame    = CGRect(origin: pos, size: size)
            let rawImage = resolveImage(element: element, description: desc, app: app)

            var item = MenuBarItem(
                id: id,
                bundleID: bundleID,
                appName: appName,
                axDescription: desc,
                frame: frame,
                isSystemItem: isSystem,
                categoryID: dtoByKey[key]?.categoryID,
                sortOrder: dtoByKey[key]?.sortOrder ?? sortIndex
            )
            item.image     = rawImage.map { processImage($0) }
            item.axElement = element

            items.append(item)
            sortIndex += 1
        }

        return items
    }

    // MARK: - Threshold

    private func statusThreshold() -> CGFloat {
        guard let screen = NSScreen.main else { return 800 }
        return screen.frame.minX + screen.frame.width * 0.55
    }

    // MARK: - AX helpers

    private func axPosition(_ e: AXUIElement) -> CGPoint {
        var r: CFTypeRef?; var p = CGPoint.zero
        if AXUIElementCopyAttributeValue(
            e, kAXPositionAttribute as CFString, &r) == .success,
           let v = r { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        return p
    }

    private func axSize(_ e: AXUIElement) -> CGSize {
        var r: CFTypeRef?; var s = CGSize.zero
        if AXUIElementCopyAttributeValue(
            e, kAXSizeAttribute as CFString, &r) == .success,
           let v = r { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return s
    }

    private func axDescription(_ e: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func axTitle(_ e: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func axRole(_ e: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    // MARK: - Image resolution

    /// Returns the best available icon for a status item.
    /// Priority: AXImage on element → AXImage on children → SF Symbol → app icon
    private func resolveImage(element: AXUIElement,
                              description: String,
                              app: NSRunningApplication) -> NSImage? {
        // 1. AX-provided image on the element itself (rare but clean)
        var imgRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXImage" as CFString, &imgRef) == .success,
           let img = imgRef as? NSImage { return img }

        // 2. AXImage on direct children (Stats 等のカスタムビューに対応)
        //    Stats の各ウィジェットは NSButton ではなくカスタム NSView のため
        //    element 自体に AXImage がない場合でも子ビューが持つことがある。
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                var childImg: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    child, "AXImage" as CFString, &childImg) == .success,
                   let img = childImg as? NSImage { return img }
            }
        }

        // 3. SF Symbol for known system items
        if let sym = sfSymbol(for: description) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            return NSImage(systemSymbolName: sym, accessibilityDescription: description)?
                .withSymbolConfiguration(cfg)
        }

        // 4. App bundle icon (high-res, always looks good)
        return app.icon
    }

    /// Maps known system status-item descriptions to SF Symbol names.
    private func sfSymbol(for description: String) -> String? {
        let map: [String: String] = [
            // Japanese names (macOS locale)
            "バッテリー":         "battery.100",
            "サウンド":           "speaker.wave.2",
            "Wi‑Fi、接続済み":    "wifi",
            "Wi‑Fi":             "wifi",
            "コントロールセンター": "switch.2",
            "時計":              "clock",
            "検索":              "magnifyingglass",
            "Spotlight":         "magnifyingglass",
            "おやすみモード":      "moon.fill",
            "スクリーンタイム":    "hourglass",
            "Bluetooth":         "bluetooth",
            "VPN":               "lock.shield",
            // English names
            "Battery":           "battery.100",
            "Sound":             "speaker.wave.2",
            "Control Center":    "switch.2",
            "Clock":             "clock",
            "Focus":             "moon.fill",
            "Screen Time":       "hourglass",
            "Siri":              "waveform",
        ]
        // Prefix match for Wi-Fi (description includes signal info after)
        if description.hasPrefix("Wi‑Fi") || description.hasPrefix("Wi-Fi") {
            return "wifi"
        }
        return map[description]
    }

    // MARK: - Image processing (spec §3.5: +10 % saturation, +5 % contrast)

    private func processImage(_ src: NSImage) -> NSImage {
        guard let tiff = src.tiffRepresentation,
              let bm = NSBitmapImageRep(data: tiff) else { return src }
        let ci = CIImage(bitmapImageRep: bm)
        let ctx = CIContext()
        guard let f = CIFilter(name: "CIColorControls") else { return src }
        f.setValue(ci,   forKey: kCIInputImageKey)
        f.setValue(1.10, forKey: kCIInputSaturationKey)
        f.setValue(1.05, forKey: kCIInputContrastKey)
        f.setValue(0.0,  forKey: kCIInputBrightnessKey)
        guard let out = f.outputImage,
              let cg  = ctx.createCGImage(out, from: out.extent) else { return src }
        return NSImage(cgImage: cg, size: src.size)
    }

    // MARK: - Helpers

    private func isSystemItem(bundleID: String?, execPath: String) -> Bool {
        if let b = bundleID, b.hasPrefix("com.apple.") { return true }
        if execPath.hasPrefix("/System/Library/") { return true }
        return false
    }

    private func stableKey(bundleID: String?, description: String, appName: String) -> String {
        "\(bundleID ?? appName)|\(description)"
    }
}
