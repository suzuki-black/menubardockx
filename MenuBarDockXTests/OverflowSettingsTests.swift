import XCTest

/// `OverflowSettings` のデフォルト値・後方互換デコード・派生プロパティを検証する。
///
/// このモデルは UserDefaults に JSON で永続化され、フィールド追加のたびに
/// スキーマバージョンを上げずに済むよう `decodeIfPresent` で個別にデフォルトを補う。
/// その「キー欠落時に旧データが壊れない」契約をテストで固定する。
final class OverflowSettingsTests: XCTestCase {

    func testDefaultValues() {
        let s = OverflowSettings()
        XCTAssertEqual(s.displayMode, .flat)
        XCTAssertEqual(s.iconWidth, 40)
        XCTAssertEqual(s.panelOpacity, 1.0)
        XCTAssertTrue(s.dismissOnClick)
        XCTAssertEqual(s.blendBrightness, 1.10, accuracy: 0.0001)
        XCTAssertEqual(s.blendSaturation, 0.88, accuracy: 0.0001)
    }

    func testUseCategoriesDerivedFromDisplayMode() {
        var s = OverflowSettings()
        s.displayMode = .flat
        XCTAssertFalse(s.useCategories)
        s.displayMode = .category
        XCTAssertTrue(s.useCategories)
    }

    func testDecodeFromEmptyJSONUsesDefaults() throws {
        // 空オブジェクトでも全フィールドがデフォルト値で埋まる（後方互換の要）
        let data = "{}".data(using: .utf8)!
        let s = try JSONDecoder().decode(OverflowSettings.self, from: data)
        XCTAssertEqual(s.displayMode, .flat)
        XCTAssertEqual(s.iconWidth, 40)
        XCTAssertEqual(s.panelOpacity, 1.0)
        XCTAssertTrue(s.dismissOnClick)
        XCTAssertEqual(s.blendBrightness, 1.10, accuracy: 0.0001)
        XCTAssertEqual(s.blendSaturation, 0.88, accuracy: 0.0001)
    }

    func testDecodePartialJSONFillsMissingFields() throws {
        // 一部キーのみ存在する旧データ（例: blend 補正フィールドが無い v3 以前）
        let json = """
        { "displayMode": "category", "iconWidth": 48 }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(OverflowSettings.self, from: json)
        XCTAssertEqual(s.displayMode, .category)
        XCTAssertEqual(s.iconWidth, 48)
        // 欠落フィールドはデフォルトで補完
        XCTAssertEqual(s.panelOpacity, 1.0)
        XCTAssertEqual(s.blendBrightness, 1.10, accuracy: 0.0001)
    }

    func testEncodeDecodeRoundTrip() throws {
        var s = OverflowSettings()
        s.displayMode     = .category
        s.iconWidth       = 36
        s.panelOpacity    = 0.5
        s.dismissOnClick  = false
        s.blendBrightness = 0.95
        s.blendSaturation = 1.05

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(OverflowSettings.self, from: data)

        XCTAssertEqual(back.displayMode, .category)
        XCTAssertEqual(back.iconWidth, 36)
        XCTAssertEqual(back.panelOpacity, 0.5)
        XCTAssertFalse(back.dismissOnClick)
        XCTAssertEqual(back.blendBrightness, 0.95, accuracy: 0.0001)
        XCTAssertEqual(back.blendSaturation, 1.05, accuracy: 0.0001)
    }

    func testDisplayModeRawValues() {
        XCTAssertEqual(OverflowDisplayMode.flat.rawValue, "flat")
        XCTAssertEqual(OverflowDisplayMode.category.rawValue, "category")
        XCTAssertEqual(OverflowDisplayMode(rawValue: "flat"), .flat)
        XCTAssertEqual(OverflowDisplayMode(rawValue: "category"), .category)
        XCTAssertNil(OverflowDisplayMode(rawValue: "unknown"))
    }
}
