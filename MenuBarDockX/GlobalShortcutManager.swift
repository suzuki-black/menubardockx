import AppKit

// MARK: - GlobalShortcutManager ───────────────────────────────────────────────
/// グローバルキーボードショートカットを管理する。
///
/// デフォルト: ⌥⌘M（Option + Command + M）でオーバーフローパネルを開く。
///
/// NSEvent.addGlobalMonitorForEvents はアプリが非アクティブでも機能するため、
/// .accessory ポリシーのメニューバーアプリに適している。
/// ただし Accessibility 権限が必要（AXIsProcessTrusted() == true）。
final class GlobalShortcutManager {

    static let shared = GlobalShortcutManager()
    private init() {}

    private var monitor: Any?

    // ⌃⌥⌘M の keyCode と修飾キー（3つの修飾キーで他アプリとの競合を最小化）
    private let targetKeyCode: UInt16 = 46   // m
    private let targetFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        ClickLog("[GlobalShortcut] started. monitor=\(monitor != nil) AX=\(AXIsProcessTrusted())")
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 修飾キーが1つ以上押されていればデバッグログ（全キーを記録すると多すぎるため）
        #if DEBUG
        if !event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty {
            ClickLog("[GlobalShortcut] keyDown keyCode=\(event.keyCode) flags=\(flags.rawValue) match=\(flags == targetFlags && event.keyCode == targetKeyCode)")
        }
        #endif
        guard flags == targetFlags, event.keyCode == targetKeyCode else { return }
        DispatchQueue.main.async {
            OverflowStatusManager.shared.togglePanel()
        }
    }
}
