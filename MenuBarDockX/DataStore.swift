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

    // MARK: - Window geometry

    var windowFrame: NSRect? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "windowFrame") else { return nil }
            return NSRectFromString(str)
        }
        set {
            UserDefaults.standard.set(newValue.map { NSStringFromRect($0) }, forKey: "windowFrame")
        }
    }

    // MARK: - Global shortcut

    struct ShortcutSpec: Codable {
        var keyCode: UInt32   // Carbon virtual key code
        var modifiers: UInt32 // Carbon modifier flags
    }

    var shortcut: ShortcutSpec {
        get {
            guard let data = UserDefaults.standard.data(forKey: "shortcut"),
                  let spec = try? JSONDecoder().decode(ShortcutSpec.self, from: data) else {
                // Default: ⌥⌘M  (optionKey=2048, cmdKey=256)
                return ShortcutSpec(keyCode: 46, modifiers: 2048 | 256)
            }
            return spec
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "shortcut")
            }
        }
    }
}
