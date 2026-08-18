import Foundation
import Testing
@testable import SecondMindKit

// SMConfig's contract: every field has a safe default, any TOML value
// overrides exactly its field, and malformed input degrades to defaults —
// the app must run with no config file at all.

private func makeTmpDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("smtest-config-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct ConfigTests {

    @Test func emptyConfigYieldsAllDefaults() {
        let c = SMConfig(toml: MiniTOML(string: ""))
        let home = NSHomeDirectory()

        #expect(c.vault == SMConfig.defaultVault)
        #expect(c.appData == home + "/Library/Application Support/2ndMind")
        #expect(c.logsDir == home + "/Library/Logs/2ndm1nd")
        #expect(c.model == "claude-opus-4-8")
        #expect(c.effort == "max")
        #expect(c.claudeTimeoutS == 900)
        #expect(c.brainIntervalMin == 60)
        #expect(c.brainMinBatch == 15)
        #expect(c.brainMaxPendingAgeMin == 180)
        #expect(c.brainMaxCallsPerDay == 12)
        #expect(c.serverPort == 4517)
        #expect(c.spanIdleCloseS == 90)
        #expect(c.neverRecordApps.contains("com.1password.1password"))
        #expect(c.neverRecordPaths.contains(home + "/.ssh"))
        #expect(c.fsWatchPaths.contains(home + "/Projects"))
    }

    @Test func tomlValuesOverrideEveryField() {
        let c = SMConfig(toml: MiniTOML(string: """
            [paths]
            vault = "/tmp/test-vault"
            appdata = "/tmp/test-appdata"
            logs = "/tmp/test-logs"
            [models]
            opus = "claude-test-1"
            [thinking]
            effort = "low"
            [claude]
            timeout_s = 60
            [brain]
            interval_min = 5
            min_batch = 3
            max_pending_age_min = 10
            max_calls_per_day = 2
            [server]
            port = 9999
            [sessionizer]
            idle_close_s = 120
            [privacy]
            never_record_apps = ["com.example.one"]
            never_record_paths = ["~/secret"]
            [sensors.filesystem]
            watch = ["~/Code", "/opt/work"]
            """))

        #expect(c.vault == "/tmp/test-vault")
        #expect(c.appData == "/tmp/test-appdata")
        #expect(c.logsDir == "/tmp/test-logs")
        #expect(c.model == "claude-test-1")
        #expect(c.effort == "low")
        #expect(c.claudeTimeoutS == 60)
        #expect(c.brainIntervalMin == 5)
        #expect(c.brainMinBatch == 3)
        #expect(c.brainMaxPendingAgeMin == 10)
        #expect(c.brainMaxCallsPerDay == 2)
        #expect(c.serverPort == 9999)
        #expect(c.spanIdleCloseS == 120)
        #expect(c.neverRecordApps == ["com.example.one"])
        // paths() accessors expand the tilde.
        #expect(c.neverRecordPaths == [NSHomeDirectory() + "/secret"])
        #expect(c.fsWatchPaths == [NSHomeDirectory() + "/Code", "/opt/work"])
    }

    @Test func malformedValuesFallBackToDefaults() {
        // Wrong types, garbage lines, and half-broken TOML must not take a
        // field down with them — each falls back to its own default.
        let c = SMConfig(toml: MiniTOML(string: """
            this line is not toml at all
            [server]
            port = "not-a-number"
            [sessionizer]
            idle_close_s =
            ===
            [brain
            interval_min = 5
            """))
        #expect(c.serverPort == 4517)
        #expect(c.spanIdleCloseS == 90)
        // "[brain" is not a valid section header, so interval_min never lands
        // under brain.* — the default survives.
        #expect(c.brainIntervalMin == 60)
        #expect(c.vault == SMConfig.defaultVault)
    }

    @Test func configFileRoundTripThroughMiniTOML() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/config.toml"
        try """
        [paths]
        vault = "\(dir)/vault"   # inline comment must be stripped
        [server]
        port = 4600
        """.write(toFile: file, atomically: true, encoding: .utf8)

        let c = SMConfig(toml: try MiniTOML(contentsOf: URL(fileURLWithPath: file)))
        #expect(c.vault == dir + "/vault")
        #expect(c.serverPort == 4600)
    }

    @Test func missingConfigFileDegradesToDefaults() {
        // The load() pattern: unreadable file → empty MiniTOML → defaults.
        let missing = URL(fileURLWithPath: "/nonexistent/definitely/config.toml")
        let toml = (try? MiniTOML(contentsOf: missing)) ?? MiniTOML(string: "")
        let c = SMConfig(toml: toml)
        #expect(c.serverPort == 4517)
        #expect(c.vault == SMConfig.defaultVault)
    }

    @Test func derivedURLsAndDirectoryCreation() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let c = SMConfig(toml: MiniTOML(string: """
            [paths]
            vault = "\(dir)/vault"
            appdata = "\(dir)/appdata"
            logs = "\(dir)/logs"
            """))

        #expect(c.ledgerURL.path == dir + "/appdata/brain.db")
        #expect(c.vaultURL.path == dir + "/vault")

        c.ensureDirectories()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir + "/appdata", isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: dir + "/logs", isDirectory: &isDir) && isDir.boolValue)
        // Calling it again on existing directories is harmless.
        c.ensureDirectories()
    }
}
