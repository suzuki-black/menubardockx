import Foundation

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable {
    case english  = "en"
    case japanese = "ja"
}

// MARK: - LanguageManager

final class LanguageManager {

    static let shared = LanguageManager()
    static let didChangeNotification = Notification.Name("LanguageManagerDidChange")

    private let udKey = "appLanguage"

    var current: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: udKey) ?? "en"
            return AppLanguage(rawValue: raw) ?? .english
        }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: udKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    var isEnglish: Bool { current == .english }

    private init() {}
}

// MARK: - L() helper

/// Return the English string when the app language is English, otherwise Japanese.
///
/// Usage:
///   L("Quit MenuBarDockX", "MenuBarDockX を終了")
@inline(__always)
func L(_ en: String, _ ja: String) -> String {
    LanguageManager.shared.isEnglish ? en : ja
}
