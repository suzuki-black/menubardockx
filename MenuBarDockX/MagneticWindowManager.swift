import AppKit

/// Handles magnet-snap of the launcher panel to screen edges and the menu bar.
final class MagneticWindowManager: NSObject {

    private weak var window: NSPanel?
    private let snapThreshold: CGFloat = 20
    private let animationDuration: TimeInterval = 0.12

    init(window: NSPanel) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Snap logic

    @objc private func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        snap(window: window)
    }

    func applySnapIfNeeded() {
        guard let window else { return }
        snap(window: window)
    }

    private func snap(window: NSPanel) {
        guard let screen = window.screen ?? NSScreen.main else { return }

        let frame        = window.frame
        let screenBounds = screen.frame          // Full pixel area including menu bar
        let visibleFrame = screen.visibleFrame   // Excludes Dock & menu bar

        // Menu bar occupies the top strip
        let menuBarHeight  = screenBounds.maxY - visibleFrame.maxY
        let menuBarBottom  = screenBounds.maxY - menuBarHeight  // Bottom edge of menu bar

        // Notch-safe horizontal range (macOS 12+ only)
        var leftBound  = screenBounds.minX
        var rightBound = screenBounds.maxX
        if #available(macOS 12.0, *) {
            let insets = screen.safeAreaInsets
            if insets.top > 0 {
                // Notch takes up the center of the top edge; leave a margin
                leftBound  = screenBounds.minX + insets.left
                rightBound = screenBounds.maxX - insets.right
            }
        }

        var snapped = frame

        // ── Top: snap to just below the menu bar ──────────────────────────────
        if abs(frame.maxY - menuBarBottom) < snapThreshold {
            snapped.origin.y = menuBarBottom - frame.height
            // Keep within notch-safe horizontal bounds
            snapped.origin.x = max(leftBound,
                                   min(snapped.origin.x, rightBound - frame.width))
        }

        // ── Bottom ────────────────────────────────────────────────────────────
        if abs(frame.minY - visibleFrame.minY) < snapThreshold {
            snapped.origin.y = visibleFrame.minY
        }

        // ── Left ──────────────────────────────────────────────────────────────
        if abs(frame.minX - screenBounds.minX) < snapThreshold {
            snapped.origin.x = screenBounds.minX
        }

        // ── Right ─────────────────────────────────────────────────────────────
        if abs(frame.maxX - screenBounds.maxX) < snapThreshold {
            snapped.origin.x = screenBounds.maxX - frame.width
        }

        guard snapped != frame else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(snapped, display: true)
        } completionHandler: {
            DataStore.shared.windowFrame = snapped
        }
    }
}
