import XCTest

// NOTE: このテストターゲットはホストレス（TEST_HOST なし）で、対象の型定義ファイル
//       （Category.swift など）を直接コンパイルして取り込む。そのため `@testable import`
//       は不要で、型は同一モジュールとして直接参照できる。

/// `Category` のプリセット定義を検証する。
///
/// プリセットの ID は永続化（categories.json / items.json の categoryID）と
/// 自動分類（ClassificationRulesManager.categoryID(forBundleID:)）の両方で
/// 「固定 UUID」として参照されるため、値が変わると既存ユーザーの分類が壊れる。
/// この回帰を防ぐためのテスト。
final class CategoryTests: XCTestCase {

    func testPresetsContainSixCategories() {
        XCTAssertEqual(Category.presets.count, 6)
    }

    func testAllItemsHasFixedUUID() {
        XCTAssertEqual(Category.allItems.id,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(Category.allItems.name, "すべて")
        XCTAssertTrue(Category.allItems.isBuiltin)
        XCTAssertEqual(Category.allItems.sortOrder, 0)
    }

    func testAllPresetsAreBuiltin() {
        XCTAssertTrue(Category.presets.allSatisfy { $0.isBuiltin })
    }

    func testPresetSortOrderIsContiguous() {
        let orders = Category.presets.map(\.sortOrder).sorted()
        XCTAssertEqual(orders, Array(0..<6))
    }

    func testPresetNamesMatchClassificationCategories() {
        // classification_rules.json が返すカテゴリ名はすべてプリセット名に存在する必要がある
        // （存在しないと categoryID(forBundleID:) が nil を返し自動分類が無効になる）。
        let names = Set(Category.presets.map(\.name))
        for required in ["開発", "クラウド", "セキュリティ", "ユーティリティ", "システム"] {
            XCTAssertTrue(names.contains(required), "プリセットに『\(required)』が必要です")
        }
    }

    func testPresetIDsAreUnique() {
        let ids = Category.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEquatableAndHashableByID() {
        let a = Category.allItems
        let b = Category(id: a.id, name: "別名", sfSymbol: "x", isBuiltin: false, sortOrder: 99)
        // == と hash は id のみで判定される
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}
