import Foundation

struct ClassificationRule: Codable {
    var bundleID: String
    var category: String
}

struct PrefixRule: Codable {
    var prefix: String
    var category: String
}

private struct RulesFile: Codable {
    var rules: [ClassificationRule]
    var prefixRules: [PrefixRule]
}

/// Loads built-in + user-defined classification rules from JSON.
final class ClassificationRulesManager {
    static let shared = ClassificationRulesManager()

    private var rules: [ClassificationRule] = []
    private var prefixRules: [PrefixRule] = []

    private let userRulesURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        userRulesURL = base.appendingPathComponent("MenuBarDockX/user_rules.json")
        reload()
    }

    func reload() {
        var allRules: [ClassificationRule] = []
        var allPrefixes: [PrefixRule] = []

        // Built-in rules bundled with the app
        if let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(RulesFile.self, from: data) {
            allRules.append(contentsOf: file.rules)
            allPrefixes.append(contentsOf: file.prefixRules)
        }

        // User-defined rules (additive, override built-in)
        if let data = try? Data(contentsOf: userRulesURL),
           let file = try? JSONDecoder().decode(RulesFile.self, from: data) {
            allRules.append(contentsOf: file.rules)
            allPrefixes.append(contentsOf: file.prefixRules)
        }

        rules = allRules
        prefixRules = allPrefixes
    }

    /// Returns the category name for a given bundleID, or nil if unclassified.
    func classify(bundleID: String?) -> String? {
        guard let bid = bundleID else { return nil }

        // Exact match first
        if let rule = rules.first(where: { $0.bundleID == bid }) {
            return rule.category
        }

        // Prefix match
        for prefixRule in prefixRules where bid.hasPrefix(prefixRule.prefix) {
            return prefixRule.category
        }

        return nil
    }

    // MARK: - User-managed rules

    func addUserRule(bundleID: String, category: String) {
        var userFile = loadUserFile()
        userFile.rules.removeAll { $0.bundleID == bundleID }
        userFile.rules.append(ClassificationRule(bundleID: bundleID, category: category))
        saveUserFile(userFile)
        reload()
    }

    func removeUserRule(bundleID: String) {
        var userFile = loadUserFile()
        userFile.rules.removeAll { $0.bundleID == bundleID }
        saveUserFile(userFile)
        reload()
    }

    private func loadUserFile() -> RulesFile {
        guard let data = try? Data(contentsOf: userRulesURL),
              let file = try? JSONDecoder().decode(RulesFile.self, from: data) else {
            return RulesFile(rules: [], prefixRules: [])
        }
        return file
    }

    private func saveUserFile(_ file: RulesFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: userRulesURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: userRulesURL, options: .atomic)
    }
}
