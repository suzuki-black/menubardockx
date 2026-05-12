import SwiftUI

// MARK: - MenuBarDockXApp ─────────────────────────────────────────────────────
/// SwiftUI App エントリーポイント。
///
/// UI はすべて AppDelegate / NSStatusItem で管理する。
/// MenuBarExtra は使用しない（Tahoe の dead zone 問題を回避するため）。
/// NSApplicationDelegateAdaptor により AppDelegate が
/// applicationDidFinishLaunching / OverflowStatusManager を担当する。
@main
struct MenuBarDockXApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 表示するウィンドウはない。NSStatusItem と NSPanel で完結する。
        Settings { EmptyView() }
    }
}
