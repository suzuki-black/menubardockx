import Foundation
import AppKit

// Runtime representation of a discovered menu bar item.
// `image` and `axElement` are not persisted — they are populated live each enumeration.
struct MenuBarItem: Identifiable, Hashable {
    var id: UUID
    var bundleID: String?
    var appName: String
    var axDescription: String
    var frame: CGRect
    var isSystemItem: Bool

    // Persisted separately in DataStore
    var categoryID: UUID?
    var sortOrder: Int

    // Runtime-only (never persisted)
    var isHidden: Bool = false   // true = notch-obscured / not currently visible
    var image: NSImage?
    var axElement: AXUIElement?

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// Lightweight Codable DTO for persistence (excludes image & axElement)
struct MenuBarItemDTO: Codable {
    var id: UUID
    var bundleID: String?
    var appName: String
    var axDescription: String
    var categoryID: UUID?
    var sortOrder: Int
    var isSystemItem: Bool

    init(from item: MenuBarItem) {
        id = item.id
        bundleID = item.bundleID
        appName = item.appName
        axDescription = item.axDescription
        categoryID = item.categoryID
        sortOrder = item.sortOrder
        isSystemItem = item.isSystemItem
    }

    func toItem() -> MenuBarItem {
        MenuBarItem(
            id: id,
            bundleID: bundleID,
            appName: appName,
            axDescription: axDescription,
            frame: .zero,
            isSystemItem: isSystemItem,
            categoryID: categoryID,
            sortOrder: sortOrder
        )
    }
}
