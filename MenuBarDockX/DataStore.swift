import Foundation
import AppKit

/// Central persistence layer. Backed by JSON files in Application Support.
final class DataStore {
    static let shared = DataStore()

    private let appSupportURL: URL
    private let categoriesURL: URL
    private let itemsURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent("MenuBarDockX", isDirectory: true)
        categoriesURL = appSupportURL.appendingPathComponent("categories.json")
        itemsURL      = appSupportURL.appendingPathComponent("items.json")
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        migrateIfNeeded()
    }

    // MARK: - Schema migration

    // 汎用スキーマバージョン（"schemaVersion" キー）。
    // overflowSettingsSchemaVersion とは別軸で管理し、設定値の意味変更に追随する。
    //
    // バージョン履歴:
    //   v4 (旧来): 既存ユーザーは "schemaVersion" キー未設定 → integer(forKey:) = 0 として扱う。
    //   v5 (現在): blendBrightness / blendSaturation を vibrancy 寄りのデフォルト値に上書き。
    //              (0.95/0.90 → 1.08/0.88)
    private static let currentSchemaVersion = 5
    private static let schemaVersionUDKey   = "schemaVersion"

    /// 現在の汎用スキーマバージョン（UserDefaults に保存された値）。
    /// キーが存在しない既存ユーザーは 0 が返るため、常に最初のマイグレーションが走る。
    var schemaVersion: Int {
        get { UserDefaults.standard.integer(forKey: Self.schemaVersionUDKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.schemaVersionUDKey) }
    }

    /// 起動時に 1 度だけ呼ばれる。schemaVersion が古ければ順次マイグレーションを適用する。
    private func migrateIfNeeded() {
        var version = schemaVersion   // 未設定の既存ユーザーは 0

        // v4 → v5: blendBrightness / blendSaturation を vibrancy 寄りの値へ上書き
        if version < 5 {
            var settings = overflowSettings
            settings.blendBrightness = 1.10
            settings.blendSaturation = 0.88
            overflowSettings = settings
            version = 5
        }

        // 将来の移行はここに追記:
        // if version < 6 { ... ; version = 6 }

        schemaVersion = version
    }

    // MARK: - Categories

    func loadCategories() -> [Category] {
        guard let data = try? Data(contentsOf: categoriesURL),
              let cats = try? JSONDecoder().decode([Category].self, from: data) else {
            return Category.presets
        }
        // Merge presets that may be missing (e.g. after an app update)
        var byID = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
        for preset in Category.presets where byID[preset.id] == nil {
            byID[preset.id] = preset
        }
        return byID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    func saveCategories(_ categories: [Category]) {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        try? data.write(to: categoriesURL, options: .atomic)
    }

    // MARK: - Item metadata (categoryID, sortOrder)

    func loadItemDTOs() -> [MenuBarItemDTO] {
        guard let data = try? Data(contentsOf: itemsURL),
              let dtos = try? JSONDecoder().decode([MenuBarItemDTO].self, from: data) else {
            return []
        }
        return dtos
    }

    func saveItemDTOs(_ dtos: [MenuBarItemDTO]) {
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        try? data.write(to: itemsURL, options: .atomic)
    }

    // MARK: - Overflow display settings

    // overflowSettingsSchemaVersion 履歴（panelOpacity 専用ガード）:
    //   v1 (初期): panelOpacity = blur.alphaValue (0.3–1.0, デフォルト 1.0)
    //   v2:        panelOpacity = solidOverlay.alphaValue (0.0–1.0, デフォルト 0.0)
    //              意味が逆転したため移行時に 0.0 へリセット
    //   v3:        v2 と同一セマンティクス。v2 移行が不完全だった場合の再リセット保証。
    //   v4 (現在): NSVisualEffectView を廃止し純 NSView + solidOverlay に移行。
    //              panelOpacity の意味: 0.0=透明, 1.0=サンプリング色のソリッド表示。
    //              デフォルトを 1.0 に変更（メニューバーと色が一致する状態）。
    //   ※ blendBrightness/blendSaturation の移行は汎用 schemaVersion (migrateIfNeeded) で管理。
    private static let settingsSchemaVersion = 4
    private static let schemaVersionKey      = "overflowSettingsSchemaVersion"

    var overflowSettings: OverflowSettings {
        get {
            // 新キーが存在すればデコード
            if let data = UserDefaults.standard.data(forKey: "overflowSettings"),
               var settings = try? JSONDecoder().decode(OverflowSettings.self, from: data) {

                // スキーマ移行: panelOpacity のセマンティクス変更に合わせてリセット
                //   v1/v2/v3 → v4: NSVisualEffectView 廃止に伴い panelOpacity を 1.0 に変更
                //   (1.0 = サンプリング色のソリッド表示 = メニューバーと色が一致する状態)
                let storedSchema = UserDefaults.standard.integer(forKey: Self.schemaVersionKey)
                if storedSchema < Self.settingsSchemaVersion {
                    settings.panelOpacity = 1.0   // NSView 方式のデフォルト (1.0 = 完全ソリッド)
                    UserDefaults.standard.set(Self.settingsSchemaVersion, forKey: Self.schemaVersionKey)
                    if let migrated = try? JSONEncoder().encode(settings) {
                        UserDefaults.standard.set(migrated, forKey: "overflowSettings")
                    }
                }
                return settings
            }
            // 旧キー ("overflowDisplayMode") からの移行処理
            var settings = OverflowSettings()
            if let raw = UserDefaults.standard.string(forKey: "overflowDisplayMode") {
                settings.displayMode = (raw == "category") ? .category : .flat
                if let data = try? JSONEncoder().encode(settings) {
                    UserDefaults.standard.set(data, forKey: "overflowSettings")
                }
                UserDefaults.standard.removeObject(forKey: "overflowDisplayMode")
            }
            // 初回起動はスキーマを最新版として記録
            UserDefaults.standard.set(Self.settingsSchemaVersion, forKey: Self.schemaVersionKey)
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "overflowSettings")
            }
        }
    }

}

// MARK: - OverflowDisplayMode ─────────────────────────────────────────────────
//
// 旧 OverflowMode (OverflowUI.swift) を DataStore に移管した型。
//   旧 .normal → 新 .flat（意味は同じ: カテゴリなしのフラット表示）
//   旧 .category → 新 .category（変更なし）
//
// UserDefaults への永続化は OverflowSettings 経由で行う。
// useCategories は displayMode から導出される計算プロパティとして提供し、
// displayMode と useCategories の不整合を構造的に防ぐ。

enum OverflowDisplayMode: String, Codable {
    case flat     = "flat"
    case category = "category"
}

struct OverflowSettings: Codable {
    var displayMode:     OverflowDisplayMode = .flat
    var iconWidth:       CGFloat             = 40    // アイコンセル幅 (32–48pt, step 2)
    var panelOpacity:    Double              = 1.0   // 背景不透明度 (0.0=透明/1.0=サンプリング色ソリッド)
    var dismissOnClick:  Bool               = true   // クリック後にパネルを閉じる
    var blendBrightness: Double             = 1.10   // 明度補正係数 (0.80〜1.20) — vibrancy 相当の明度に合わせる
    var blendSaturation: Double             = 0.88   // 彩度補正係数 (0.70〜1.10) — vibrancy 相当の低彩度に合わせる

    /// displayMode から導出 — displayMode と useCategories の整合性を保証する。
    var useCategories: Bool { displayMode == .category }

    // ── 後方互換デコード ───────────────────────────────────────────────────
    // Swift の自動合成 Codable はキーが欠落すると decode 失敗するため、
    // decodeIfPresent で各プロパティにデフォルト値を提供する。
    // 新フィールド追加のたびにスキーマバージョンを上げずに済む。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayMode     = try c.decodeIfPresent(OverflowDisplayMode.self, forKey: .displayMode)     ?? .flat
        iconWidth       = try c.decodeIfPresent(CGFloat.self,             forKey: .iconWidth)        ?? 40
        panelOpacity    = try c.decodeIfPresent(Double.self,              forKey: .panelOpacity)     ?? 1.0
        dismissOnClick  = try c.decodeIfPresent(Bool.self,                forKey: .dismissOnClick)   ?? true
        blendBrightness = try c.decodeIfPresent(Double.self,              forKey: .blendBrightness)  ?? 1.10
        blendSaturation = try c.decodeIfPresent(Double.self,              forKey: .blendSaturation)  ?? 0.88
    }
}
