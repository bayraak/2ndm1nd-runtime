import Foundation
import Testing
@testable import SecondMindKit

// Every test opens its own DatabasePool in a fresh temp directory — no shared
// state, no TCC, no network. GRDB DatabasePool needs a real file (WAL), so
// in-memory is not an option; a per-test temp dir is.

private func makeTmpDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("smtest-store-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func makeStore(_ dir: String) throws -> EventStore {
    try EventStore(url: URL(fileURLWithPath: dir + "/brain.db"))
}

@Suite struct EventStoreTests {

    // MARK: - CRUD round-trip

    @Test func insertAndCountRoundTrip() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        #expect(try store.eventCount() == 0)
        #expect(try store.maxEventId() == 0)

        try store.insert([
            SMEvent(ts: 1000, source: "focus", kind: "app-activated", app: "com.apple.Terminal"),
            SMEvent(ts: 1001, source: "input", kind: "typed", text: "hello world"),
            SMEvent(ts: 1002, source: "git", kind: "commit", text: "fix the thing"),
        ])
        #expect(try store.eventCount() == 3)
        #expect(try store.maxEventId() == 3)

        // Empty batch is a no-op, not an error.
        try store.insert([SMEvent]())
        #expect(try store.eventCount() == 3)
    }

    @Test func eventPayloadSerializesToSortedJSON() {
        let e = SMEvent(source: "focus", kind: "snapshot", payload: ["b": 1, "a": "x"])
        #expect(e.payload == #"{"a":"x","b":1}"#)
        // Default payload is the empty JSON object, never an empty string.
        #expect(SMEvent(source: "focus", kind: "snapshot").payload == "{}")
    }

    @Test func spanInsertSetsIdAndDayIsDerivedFromT0() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        let t0 = Date().timeIntervalSince1970
        var span = SMSpan(t0: t0, t1: t0 + 600, activity: "coding", app: "com.apple.dt.Xcode",
                          project: "secondmind", title: nil)
        // day must match the same local-date rendering of t0 the store uses.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let expectedDay = f.string(from: Date(timeIntervalSince1970: t0))
        #expect(span.day == expectedDay)

        try store.insert(&span)
        #expect(span.id != nil)

        var second = SMSpan(t0: t0 + 700, t1: t0 + 800, activity: "browsing", app: nil,
                            project: nil, title: nil)
        try store.insert(&second)
        // lastInsertedRowID inside the same transaction: strictly increasing ids.
        #expect(second.id! > span.id!)
    }

    @Test func spansForDayAreOrderedByStartTime() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        let base = Date().timeIntervalSince1970
        // Insert out of order; read must come back ordered by t0.
        var late = SMSpan(t0: base + 3600, t1: base + 3700, activity: "browsing", app: nil, project: nil, title: nil)
        var early = SMSpan(t0: base, t1: base + 60, activity: "coding", app: nil, project: nil, title: nil)
        try store.insert(&late)
        try store.insert(&early)

        let day = late.day
        let fetched = try store.spans(day: day)
        #expect(fetched.count == 2)
        #expect(fetched[0].t0 <= fetched[1].t0)
        #expect(fetched[0].activity == "coding")

        // A different day returns nothing.
        #expect(try store.spans(day: "1970-01-01").isEmpty)
    }

    // MARK: - FTS

    @Test func ftsMatchesIndexedTextOnly() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        try store.insert([
            SMEvent(ts: 1, source: "input", kind: "typed", app: "dev.zed.Zed", text: "swift concurrency rocks"),
            SMEvent(ts: 2, source: "git", kind: "commit", text: "grdb sqlite migration"),
            SMEvent(ts: 3, source: "focus", kind: "app-activated", text: nil),  // nil text: never indexed
        ])

        let hits = try store.search("swift")
        #expect(hits.count == 1)
        #expect(hits[0]["source"] as? String == "input")
        #expect((hits[0]["snippet"] as? String)?.contains("«swift»") == true)

        #expect(try store.search("sqlite").count == 1)
        #expect(try store.search("nonexistentterm").isEmpty)
    }

    @Test func ftsIsCaseInsensitiveAndAnyToken() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)
        try store.insert([
            SMEvent(ts: 1, source: "input", kind: "typed", text: "Swift concurrency rocks"),
        ])
        // unicode61 tokenizer folds case.
        #expect(try store.search("SWIFT").count == 1)
        // matchingAnyTokenIn: one matching token out of two is enough.
        #expect(try store.search("swift zebra").count == 1)
    }

    @Test func pruneDeletesOldEventsAndTheirFTSRows() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        let now = Date().timeIntervalSince1970
        try store.insert([
            SMEvent(ts: now - 10 * 86400, source: "input", kind: "typed", text: "ancientterm one"),
            SMEvent(ts: now - 9 * 86400, source: "input", kind: "typed", text: "ancientterm two"),
            SMEvent(ts: now, source: "input", kind: "typed", text: "freshterm"),
        ])
        #expect(try store.search("ancientterm").count == 2)

        let deleted = try store.pruneEvents(olderThanDays: 5)
        #expect(deleted == 2)
        #expect(try store.eventCount() == 1)
        // The AFTER DELETE trigger must have scrubbed the FTS index too.
        #expect(try store.search("ancientterm").isEmpty)
        #expect(try store.search("freshterm").count == 1)
    }

    // MARK: - rawQuery guard

    @Test func rawQueryAllowsOnlySelectAndWith() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)
        try store.insert([SMEvent(ts: 1, source: "input", kind: "typed", text: "keepme")])

        // SELECT and WITH pass, case- and whitespace-insensitively.
        #expect(try store.rawQuery("SELECT COUNT(*) AS n FROM events").count == 1)
        #expect(try store.rawQuery("  select 1 as x").count == 1)
        let cte = try store.rawQuery("WITH t AS (SELECT 2 AS y) SELECT * FROM t")
        #expect(cte.first?["y"] as? Int64 == 2)

        // Anything else is refused before touching the database.
        #expect(throws: (any Error).self) { try store.rawQuery("DELETE FROM events") }
        #expect(throws: (any Error).self) { try store.rawQuery("UPDATE events SET text = 'x'") }
        #expect(throws: (any Error).self) { try store.rawQuery("PRAGMA user_version = 9") }
        #expect(try store.eventCount() == 1)   // nothing was mutated by the attempts
    }

    @Test func rawQueryCapsRowsAtLimit() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)
        try store.insert((0..<5).map { SMEvent(ts: Double($0), source: "focus", kind: "tick") })
        #expect(try store.rawQuery("SELECT * FROM events", limit: 2).count == 2)
    }

    // MARK: - Meaningful-event cursor

    @Test func meaningfulFilterCountsRealSignalOnly() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)

        try store.insert([
            SMEvent(ts: 100, source: "focus", kind: "app-activated"),            // heartbeat: no
            SMEvent(ts: 200, source: "input", kind: "typed", text: "real words"), // yes
            SMEvent(ts: 300, source: "input", kind: "activity", text: nil),       // input w/o text: no
            SMEvent(ts: 400, source: "git", kind: "commit"),                      // yes
            SMEvent(ts: 500, source: "power", kind: "snapshot"),                  // no
        ])

        #expect(try store.meaningfulEventCount(sinceId: 0) == 2)
        #expect(try store.oldestMeaningfulTs(sinceId: 0) == 200)

        // Cursor semantics: ids at/below sinceId are consumed.
        let maxId = try store.maxEventId()
        #expect(try store.meaningfulEventCount(sinceId: maxId) == 0)
        #expect(try store.oldestMeaningfulTs(sinceId: maxId) == nil)
    }

    // MARK: - Read-only handle

    @Test func readOnlyStoreReadsButRejectsWrites() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/brain.db")
        let writer = try EventStore(url: url)
        try writer.insert([SMEvent(ts: 1, source: "input", kind: "typed", text: "hello")])

        let ro = try EventStore(url: url, readOnly: true)
        #expect(try ro.eventCount() == 1)
        #expect(throws: (any Error).self) {
            try ro.insert([SMEvent(ts: 2, source: "input", kind: "typed")])
        }
    }

    // MARK: - Buffered writer

    @Test func eventWriterFlushNowPersistsBuffered() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)
        let writer = EventWriter(store: store)

        await writer.append(SMEvent(ts: 1, source: "input", kind: "typed", text: "buffered"))
        await writer.flushNow()
        #expect(try store.eventCount() == 1)

        // Flushing an empty buffer is a no-op.
        await writer.flushNow()
        #expect(try store.eventCount() == 1)
    }

    @Test func eventWriterAutoFlushesAtThreshold() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try makeStore(dir)
        let writer = EventWriter(store: store)

        // 200 appends must hit the flush threshold without an explicit flush.
        for i in 0..<200 {
            await writer.append(SMEvent(ts: Double(i), source: "focus", kind: "tick"))
        }
        #expect(try store.eventCount() == 200)
    }
}
