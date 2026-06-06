import XCTest

/// `MenuBarItem` / `MenuBarItemDTO` の変換・同値性を検証する。
///
/// DTO はパネルの並び順（sortOrder）とカテゴリ（categoryID）を再起動後に
/// 復元するための永続化表現。image / axElement はランタイム専用で永続化されない。
final class MenuBarItemTests: XCTestCase {

    private func makeItem() -> MenuBarItem {
        var item = MenuBarItem(
            id: UUID(),
            bundleID: "com.example.app",
            appName: "Example",
            axDescription: "Status",
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            isSystemItem: false,
            categoryID: Category.allItems.id,
            sortOrder: 3
        )
        item.isHidden = true
        return item
    }

    func testDTOCopiesPersistedFields() {
        let item = makeItem()
        let dto  = MenuBarItemDTO(from: item)
        XCTAssertEqual(dto.id, item.id)
        XCTAssertEqual(dto.bundleID, item.bundleID)
        XCTAssertEqual(dto.appName, item.appName)
        XCTAssertEqual(dto.axDescription, item.axDescription)
        XCTAssertEqual(dto.categoryID, item.categoryID)
        XCTAssertEqual(dto.sortOrder, item.sortOrder)
        XCTAssertEqual(dto.isSystemItem, item.isSystemItem)
    }

    func testDTORoundTripPreservesIdentity() {
        let original = makeItem()
        let restored = MenuBarItemDTO(from: original).toItem()
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.categoryID, original.categoryID)
        XCTAssertEqual(restored.sortOrder, original.sortOrder)
        // toItem() は frame を .zero に初期化する（ランタイムで再取得するため）
        XCTAssertEqual(restored.frame, .zero)
    }

    func testDTOIsCodableRoundTrip() throws {
        let dto  = MenuBarItemDTO(from: makeItem())
        let data = try JSONEncoder().encode(dto)
        let back = try JSONDecoder().decode(MenuBarItemDTO.self, from: data)
        XCTAssertEqual(back.id, dto.id)
        XCTAssertEqual(back.bundleID, dto.bundleID)
        XCTAssertEqual(back.categoryID, dto.categoryID)
        XCTAssertEqual(back.sortOrder, dto.sortOrder)
    }

    func testEqualityIsByIDOnly() {
        let a = makeItem()
        var b = a
        b.appName       = "別アプリ"
        b.axDescription = "別の説明"
        b.sortOrder     = 999
        // id が同じなら、他のフィールドが違っても等価
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testDifferentIDsAreNotEqual() {
        let a = makeItem()
        var b = a
        b.id = UUID()
        XCTAssertNotEqual(a, b)
    }
}
