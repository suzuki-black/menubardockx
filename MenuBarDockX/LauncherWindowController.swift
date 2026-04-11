import AppKit

/// Manages the floating launcher panel (the main UI).
final class LauncherWindowController: NSWindowController {

    private var magneticManager: MagneticWindowManager?
    private let launcherVC = LauncherViewController()

    // Default panel size
    private static let defaultSize = NSSize(width: 480, height: 480)

    // Accept an optional shared enumerator (currently unused by VC, reserved for future sharing)
    convenience init(enumerator: MenuBarEnumerator? = nil) {
        let panel = Self.makePanel()
        self.init(window: panel)
        panel.contentViewController = launcherVC
        panel.delegate = self
        magneticManager = MagneticWindowManager(window: panel)
        restoreWindowPosition()
    }

    // MARK: - Panel factory

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 360, height: 300)

        // Shadow: 0 8px 24px rgba(0,0,0,0.25)
        panel.hasShadow = true

        return panel
    }

    // MARK: - Show / Hide

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            close()
        } else {
            showPanel()
        }
    }

    func preloadItems() {
        launcherVC.refreshItems()
    }

    func showPanel() {
        guard let window else { return }
        if !window.isVisible {
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        magneticManager?.applySnapIfNeeded()
    }

    override func close() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
            self?.window?.alphaValue = 1
        }
    }

    // MARK: - Position persistence

    private func restoreWindowPosition() {
        guard let window else { return }
        if let saved = DataStore.shared.windowFrame {
            window.setFrame(saved, display: false)
        } else {
            window.center()
        }
    }
}

// MARK: - NSWindowDelegate

extension LauncherWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        DataStore.shared.windowFrame = frame
    }

    func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        DataStore.shared.windowFrame = frame
    }
}
