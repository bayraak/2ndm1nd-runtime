import Foundation
import Testing
@testable import SecondMindKit

// Sessionizer tests drive rebuild(day:) over synthetic focus events in a
// temp-dir store, with the vault pointed at a temp dir so the markdown
// surface lands somewhere disposable. A fixed mid-January day avoids DST
// edges; all epoch math goes through Sessionizer.dayStart so the tests use
// the exact same local-time anchor as the code under test.

private let testDay = "2026-01-15"

private func makeTmpDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("smtest-sess-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func makeFixture(idleCloseS: Int = 90) throws -> (dir: String, config: SMConfig, store: EventStore, sess: Sessionizer) {
    let dir = try makeTmpDir()
    let config = SMConfig(toml: MiniTOML(string: """
        [paths]
        vault = "\(dir)/vault"
        [sessionizer]
        idle_close_s = \(idleCloseS)
        """))
    let store = try EventStore(url: URL(fileURLWithPath: dir + "/brain.db"))
    return (dir, config, store, Sessionizer(config: config, store: store))
}

private func focusEvent(ts: Double, app: String = "com.microsoft.VSCode",
                        family: String? = "ide", project: String? = nil,
                        chat: String? = nil, cwd: String? = nil) -> SMEvent {
    var payload: [String: Any] = [:]
    if let family { payload["family"] = family }
    if let project { payload["project"] = project }
    if let chat { payload["chat"] = chat }
    if let cwd { payload["terminal_cwd"] = cwd }
    return SMEvent(ts: ts, source: "focus", kind: "app-activated", app: app, payload: payload)
}

@Suite struct SessionizerTests {

    @Test func contiguousSameActivityEventsFoldIntoOneSpan() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base),
            focusEvent(ts: base + 60, project: "alpha"),
            focusEvent(ts: base + 120),
            focusEvent(ts: base + 180),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.count == 1)
        let s = try #require(spans.first)
        #expect(s.activity == "coding")
        #expect(s.t0 == base)
        #expect(s.t1 == base + 180)          // fill-to-next; last event adds no dwell
        #expect(s.project == "alpha")        // picked up mid-span, kept
        #expect(s.evidence?.contains(#""focus":4"#) == true)
    }

    @Test func gapBeyondIdleThresholdSplitsSpans() throws {
        let (dir, _, store, sess) = try makeFixture(idleCloseS: 90)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base),
            focusEvent(ts: base + 60),
            // 10-minute silence — far past idle_close_s.
            focusEvent(ts: base + 660),
            focusEvent(ts: base + 720),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.count == 2)
        #expect(spans[0].t0 == base)
        #expect(spans[0].t1 == base + 150)   // 60s to next event + 90s dwell cap into the gap
        #expect(spans[1].t0 == base + 660)
        #expect(spans[1].t1 == base + 720)
        #expect(spans.allSatisfy { $0.activity == "coding" })
    }

    @Test func activityChangeSplitsEvenWithoutAGap() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, family: "ide"),
            focusEvent(ts: base + 60, family: "ide"),
            focusEvent(ts: base + 120, app: "com.apple.Safari", family: "browser"),
            focusEvent(ts: base + 180, app: "com.apple.Safari", family: "browser"),
            focusEvent(ts: base + 240, app: "com.apple.Safari", family: "browser"),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.map(\.activity) == ["coding", "browsing"])
        #expect(spans[0].t1 <= spans[1].t0)
    }

    @Test func terminalAndIdeStayOneCodingSpan() throws {
        // Continuity is by ACTIVITY: Terminal↔VSCode is one "coding" span.
        // The Terminal event carries no payload family — the bundle-id
        // fallback (FocusContext.family) must classify it.
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, app: "com.apple.Terminal", family: nil),
            focusEvent(ts: base + 60, app: "com.microsoft.VSCode", family: "ide"),
            focusEvent(ts: base + 120, app: "com.apple.Terminal", family: nil),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.count == 1)
        #expect(spans.first?.activity == "coding")
    }

    @Test func terminalCwdBecomesTheProject() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, app: "com.apple.Terminal", family: "terminal", cwd: "/Users/x/Projects/beta"),
            focusEvent(ts: base + 60, app: "com.apple.Terminal", family: "terminal", cwd: "/Users/x/Projects/beta"),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.count == 1)
        #expect(spans.first?.project == "beta")   // lastPathComponent of terminal_cwd
    }

    @Test func dominantAppWinsTheSpan() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, app: "com.microsoft.VSCode"),
            focusEvent(ts: base + 60, app: "com.apple.dt.Xcode"),
            focusEvent(ts: base + 120, app: "com.microsoft.VSCode"),
            focusEvent(ts: base + 180, app: "com.microsoft.VSCode"),
        ])
        let spans = try sess.rebuild(day: testDay)
        #expect(spans.first?.app == "com.microsoft.VSCode")
    }

    @Test func shortAnonymousSpanIsNoiseButEntityKeepsIt() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        // A 10-second browser tap cut off by an activity switch: <30s, no
        // project, no entity → noise, dropped. The chat event that follows is
        // the day's last event (1-second closing span) but carries an entity
        // → kept despite its length.
        try store.insert([
            focusEvent(ts: base, app: "com.apple.Safari", family: "browser"),
            focusEvent(ts: base + 10, app: "com.tinyspeck.slackmacgap", family: "chat", chat: "Alice"),
        ])
        let spans = try sess.rebuild(day: testDay)

        #expect(spans.count == 1)
        let s = try #require(spans.first)
        #expect(s.activity == "chatting")
        #expect(s.entities?.contains("Alice") == true)
    }

    @Test func rebuildIsIdempotentAndPersistsOrdered() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, project: "alpha"),
            focusEvent(ts: base + 60, project: "alpha"),
            focusEvent(ts: base + 660, app: "com.apple.Safari", family: "browser"),
            focusEvent(ts: base + 720, app: "com.apple.Safari", family: "browser"),
        ])

        let first = try sess.rebuild(day: testDay)
        let second = try sess.rebuild(day: testDay)   // clears + rewrites the day

        #expect(first.count == second.count)
        let persisted = try store.spans(day: testDay)
        #expect(persisted.count == first.count)       // no duplicates from re-runs
        #expect(persisted.map(\.t0) == persisted.map(\.t0).sorted())
    }

    @Test func eventsOutsideTheDayAreIgnored() throws {
        let (dir, _, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dayStart = Sessionizer.dayStart(testDay)

        try store.insert([
            focusEvent(ts: dayStart - 100, project: "yesterday"),
            focusEvent(ts: dayStart + 86400 + 100, project: "tomorrow"),
        ])
        #expect(try sess.rebuild(day: testDay).isEmpty)
    }

    @Test func markdownSurfaceIsWritten() throws {
        let (dir, config, store, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Sessionizer.dayStart(testDay) + 3600

        try store.insert([
            focusEvent(ts: base, project: "alpha"),
            focusEvent(ts: base + 300, project: "alpha"),
        ])
        try sess.rebuild(day: testDay)

        let path = config.vault + "/Atlas/AI/spans/\(testDay).md"
        let md = try String(contentsOfFile: path, encoding: .utf8)
        #expect(md.contains("# Activity — \(testDay)"))
        #expect(md.contains("type: activity-spans"))
        #expect(md.contains("coding"))
        #expect(md.contains("alpha"))
    }

    @Test func emptyDayWritesTheEmptyMarker() throws {
        let (dir, config, _, sess) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(try sess.rebuild(day: testDay).isEmpty)
        let md = try String(contentsOfFile: config.vault + "/Atlas/AI/spans/\(testDay).md", encoding: .utf8)
        #expect(md.contains("_No activity spans recorded._"))
    }
}
