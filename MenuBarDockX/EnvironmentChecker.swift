import Foundation
import AppKit
import ApplicationServices

enum VersionSupport {
    case supported(String)
    case unsupported(String)
}

enum RosettaStatus {
    case nativeAppleSilicon
    case runningUnderRosetta
    case intel
    case unknown
}

struct EnvironmentReport {
    var hasAccessibility: Bool
    var versionSupport: VersionSupport
    var rosettaStatus: RosettaStatus
    var canReadMenuBar: Bool

    var isFullyOperational: Bool {
        guard hasAccessibility else { return false }
        if case .supported = versionSupport { return true }
        return false
    }
}

final class EnvironmentChecker {

    static func run() -> EnvironmentReport {
        EnvironmentReport(
            hasAccessibility: checkAccessibility(),
            versionSupport: checkMacOSVersion(),
            rosettaStatus: checkRosetta(),
            canReadMenuBar: checkMenuBarAccess()
        )
    }

    // MARK: - Accessibility

    static func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - macOS version

    static func checkMacOSVersion() -> VersionSupport {
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        let label = "macOS \(ver.majorVersion).\(ver.minorVersion)"
        // Support Sonoma (14), Sequoia (15), and any newer release
        if ver.majorVersion >= 14 {
            return .supported(label)
        }
        return .unsupported(label)
    }

    // MARK: - Rosetta 2

    /// Detect whether the process is running under Rosetta 2 translation.
    /// Uses `sysctl.proc_translated` which returns 1 when the process is
    /// an x86_64 binary translated by Rosetta on Apple Silicon.
    static func checkRosetta() -> RosettaStatus {
        // sysctl.proc_translated: 1 = translated under Rosetta, 0 = native
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)

        if result == 0 {
            return translated == 1 ? .runningUnderRosetta : .nativeAppleSilicon
        }

        // Key not found → either Intel Mac or pre-Rosetta macOS version
        // Verify via pgrep oahd as a secondary check (仕様 3.9.5)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["oahd"]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? .runningUnderRosetta : .intel
        } catch {
            return .unknown
        }
    }

    // MARK: - Menu bar access

    static func checkMenuBarAccess() -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                                && $0.activationPolicy == .regular }) else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var menuBar: CFTypeRef?
        return AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBar) == .success
    }

    // MARK: - Present report

    static func presentReport(_ report: EnvironmentReport, in window: NSWindow?) {
        guard !report.isFullyOperational else { return }

        var messages: [String] = []

        if !report.hasAccessibility {
            messages.append("アクセシビリティ権限が必要です。\nシステム設定 › プライバシーとセキュリティ › アクセシビリティ で「MenuBarDockX」を許可してください。")
        }
        if case .unsupported(let v) = report.versionSupport {
            messages.append("\(v) はサポート対象外です（Sequoia 15 / Sonoma 14 のみ対応）。")
        }
        if case .runningUnderRosetta = report.rosettaStatus {
            messages.append("Rosetta 2 下で動作しています。一部機能が制限される場合があります。")
        }

        guard !messages.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "MenuBarDockX — 環境チェック"
        alert.informativeText = messages.joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn && !report.hasAccessibility {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}
