import AppKit
import ServiceManagement

// MARK: - LoginItemManager ─────────────────────────────────────────────────────
/// SMAppService を使ったログイン項目（自動起動）の登録・解除を管理する。
///
/// # Tahoe での起動順序と位置の関係
/// macOS 26 Tahoe ではメニューバー右ゾーン（約 664pt）の空きが少ない場合、
/// 後から起動した NSStatusItem / MenuBarExtra はノッチ左の dead zone（x≈618）に
/// 押し出されてしまう。先にログイン時から起動しておくことで iStatMenus 等より
/// 先にスロットを確保できる。
///
/// SMAppService.mainApp を使うことで従来の LoginItems フォルダ方式に比べ
/// より信頼性が高く、System Settings > General > Login Items に表示される。

final class LoginItemManager {

    static let shared = LoginItemManager()
    private init() {}

    // MARK: - Status

    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return legacyIsEnabled()
        }
    }

    // MARK: - Register / Unregister

    /// ログイン項目を登録する。すでに登録済みの場合は何もしない。
    @discardableResult
    func enable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return true
            } catch {
                NSLog("[LoginItemManager] register failed: \(error)")
                return false
            }
        } else {
            return legacyEnable()
        }
    }

    /// ログイン項目の登録を解除する。
    @discardableResult
    func disable() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                return true
            } catch {
                NSLog("[LoginItemManager] unregister failed: \(error)")
                return false
            }
        } else {
            return legacyDisable()
        }
    }

    // MARK: - Open System Settings

    /// System Settings > General > Login Items を開く。
    func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Legacy (macOS 12 and earlier)

    private func legacyIsEnabled() -> Bool {
        // macOS 12 以前: LSSharedFileList は macOS 10.11 で deprecated。
        // Bundle ID で判定する簡易実装（精度は低い）。
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let apps = NSWorkspace.shared.runningApplications
        // 起動済みかどうかではなく、ユーザーのログイン項目 plist を読んで判定するのが理想だが
        // SandBox 外でも直接読み込むのはリスクがあるため、ここでは常に false を返す。
        _ = apps
        _ = bundleID
        return false
    }

    private func legacyEnable() -> Bool {
        openLoginItemsSettings()
        return false
    }

    private func legacyDisable() -> Bool {
        openLoginItemsSettings()
        return false
    }
}
