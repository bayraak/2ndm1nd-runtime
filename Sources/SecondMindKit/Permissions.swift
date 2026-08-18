// Permissions — preflight every TCC grant the sensors need, loudly.
// The v1 lesson: CGEventTap "succeeds" without Input Monitoring and delivers
// nothing — a silently dead sensor for 26 days. v2 makes grant state a
// first-class, always-visible signal (menu badge + onboarding window).

import ApplicationServices
import CoreGraphics
import Foundation

public enum GrantState: String, Sendable {
    case granted, denied, unknown
}

public struct PermissionStatus: Sendable {
    public var accessibility: GrantState
    public var inputMonitoring: GrantState
    public var fullDiskAccess: GrantState

    public var allGranted: Bool {
        accessibility == .granted && inputMonitoring == .granted && fullDiskAccess == .granted
    }

    public var summary: [String: String] {
        [
            "accessibility": accessibility.rawValue,
            "input_monitoring": inputMonitoring.rawValue,
            "full_disk_access": fullDiskAccess.rawValue,
        ]
    }
}

public enum Permissions {
    public static func check() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .denied,
            fullDiskAccess: checkFullDiskAccess()
        )
    }

    /// FDA has no preflight API — probe a TCC-protected file. Readable only
    /// with Full Disk Access. (Safari's Bookmarks is a stable canary.)
    static func checkFullDiskAccess() -> GrantState {
        let canaries = [
            NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
            NSHomeDirectory() + "/Library/Messages/chat.db",
        ]
        for c in canaries where FileManager.default.fileExists(atPath: c) {
            return FileManager.default.isReadableFile(atPath: c) ? .granted : .denied
        }
        // Canaries missing entirely (fresh account) — can't tell.
        return .unknown
    }

    /// Trigger the system prompts (safe to call repeatedly).
    public static func request() {
        if !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    public static let settingsURLs: [String: String] = [
        "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "input_monitoring": "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        "full_disk_access": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "automation": "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
    ]
}
