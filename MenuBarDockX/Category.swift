import Foundation

struct Category: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var sfSymbol: String   // SF Symbols name for the tab icon
    var isBuiltin: Bool    // Built-in presets cannot be deleted
    var sortOrder: Int

    static func == (lhs: Category, rhs: Category) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let allItems = Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                   name: "すべて", sfSymbol: "square.grid.2x2", isBuiltin: true, sortOrder: 0)

    // Preset categories shipped with the app
    static let presets: [Category] = [
        allItems,
        Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                 name: "システム", sfSymbol: "gearshape.fill", isBuiltin: true, sortOrder: 1),
        Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                 name: "開発", sfSymbol: "terminal.fill", isBuiltin: true, sortOrder: 2),
        Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                 name: "クラウド", sfSymbol: "cloud.fill", isBuiltin: true, sortOrder: 3),
        Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                 name: "セキュリティ", sfSymbol: "lock.shield.fill", isBuiltin: true, sortOrder: 4),
        Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                 name: "ユーティリティ", sfSymbol: "wrench.and.screwdriver.fill", isBuiltin: true, sortOrder: 5),
    ]
}
