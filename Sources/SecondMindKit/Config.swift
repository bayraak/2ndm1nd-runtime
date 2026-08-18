// SMConfig — the single typed configuration for 2ndMind v2.
// SSOT file: <vault>/Efforts/Active/2ndmind-v2/config.toml
// Override location for tests with SECONDMIND_CONFIG=/path/to/config.toml.
// Every field has a safe default: the app must run even with no config file.

import Foundation

public struct SMConfig: Sendable {
    // Paths
    public var vault: String
    public var appData: String
    public var logsDir: String

    // Claude
    public var model: String
    public var effort: String
    public var claudeTimeoutS: Int

    // Brain loop (ralph-style): periodic tick over the ledger queue.
    public var brainIntervalMin: Int        // how often the tick fires
    public var brainMinBatch: Int           // skip the claude call below this many pending events
    public var brainMaxPendingAgeMin: Int   // …unless the oldest pending item is older than this
    public var brainMaxCallsPerDay: Int     // hard wrapper-enforced daily claude budget

    // Server
    public var serverPort: Int

    // Sessionizer
    public var spanIdleCloseS: Int

    // Privacy floor (password contexts ONLY — user directive 2026-07-11: no
    // content redaction anywhere else; this is a personal verbatim ledger)
    public var neverRecordApps: [String]
    public var neverRecordPaths: [String]

    // Project roots the git connector scans for repos.
    public var fsWatchPaths: [String]

    public static let defaultVault = NSHomeDirectory() + "/Projects/2ndm1nd"

    public static func configURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["SECONDMIND_CONFIG"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: defaultVault + "/Efforts/Active/2ndmind-v2/config.toml")
    }

    public static func load() -> SMConfig {
        let toml = (try? MiniTOML(contentsOf: configURL())) ?? MiniTOML(string: "")
        return SMConfig(toml: toml)
    }

    public init(toml: MiniTOML) {
        let home = NSHomeDirectory()
        vault = toml.path("paths.vault") ?? Self.defaultVault
        appData = toml.path("paths.appdata") ?? home + "/Library/Application Support/2ndMind"
        logsDir = toml.path("paths.logs") ?? home + "/Library/Logs/2ndm1nd"

        model = toml.string("models.opus") ?? "claude-opus-4-8"
        effort = toml.string("thinking.effort") ?? "max"
        claudeTimeoutS = toml.int("claude.timeout_s") ?? 900

        brainIntervalMin = toml.int("brain.interval_min") ?? 60
        brainMinBatch = toml.int("brain.min_batch") ?? 15
        brainMaxPendingAgeMin = toml.int("brain.max_pending_age_min") ?? 180
        brainMaxCallsPerDay = toml.int("brain.max_calls_per_day") ?? 12

        serverPort = toml.int("server.port") ?? 4517
        spanIdleCloseS = toml.int("sessionizer.idle_close_s") ?? 90

        neverRecordApps = toml.array("privacy.never_record_apps") ?? [
            "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
        ]
        neverRecordPaths = toml.paths("privacy.never_record_paths") ?? [
            Self.defaultVault + "/Atlas/Personal", home + "/.ssh", home + "/.aws",
        ]
        fsWatchPaths = toml.paths("sensors.filesystem.watch") ?? [
            home + "/Documents", home + "/Downloads", home + "/Desktop", home + "/Projects",
        ]
    }

    /// Ensure runtime directories exist.
    public func ensureDirectories() {
        let fm = FileManager.default
        for dir in [appData, logsDir] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    public var ledgerURL: URL { URL(fileURLWithPath: appData + "/brain.db") }
    public var vaultURL: URL { URL(fileURLWithPath: vault) }
}
