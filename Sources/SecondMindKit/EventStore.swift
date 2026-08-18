// EventStore — the ledger. One SQLite file (GRDB, WAL) holding every raw
// event + activity spans + FTS5 index. Sensors append via the buffered
// writer; the `brain` CLI and BrainServer read concurrently (WAL readers).

import Foundation
import GRDB

public struct SMEvent: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "events"

    public var id: Int64?
    public var ts: Double          // unix epoch seconds
    public var source: String      // focus | input | fs | clipboard | power | ...
    public var kind: String        // app-activated | fs-event | session-emitted | ...
    public var app: String?        // bundle id / browser / ide
    public var text: String?       // searchable extracted text (FTS-indexed)
    public var payload: String     // JSON blob with full detail
    public var spanId: Int64?

    public init(ts: Double = Date().timeIntervalSince1970, source: String, kind: String,
                app: String? = nil, text: String? = nil, payload: [String: Any] = [:], spanId: Int64? = nil) {
        self.ts = ts
        self.source = source
        self.kind = kind
        self.app = app
        self.text = text
        self.payload = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.spanId = spanId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SMSpan: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "spans"

    public var id: Int64?
    public var t0: Double
    public var t1: Double
    public var activity: String    // coding | chat | browsing | meeting | idle | ...
    public var app: String?
    public var project: String?
    public var title: String?      // human-readable one-liner
    public var entities: String?   // JSON array of entity names
    public var evidence: String?   // JSON: event counts by source
    public var day: String         // YYYY-MM-DD (local) for cheap date queries

    public init(t0: Double, t1: Double, activity: String, app: String?, project: String?,
                title: String?, entities: [String] = [], evidence: [String: Any] = [:]) {
        self.t0 = t0
        self.t1 = t1
        self.activity = activity
        self.app = app
        self.project = project
        self.title = title
        self.entities = (try? JSONSerialization.data(withJSONObject: entities))
            .flatMap { String(data: $0, encoding: .utf8) }
        self.evidence = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        self.day = f.string(from: Date(timeIntervalSince1970: t0))
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public final class EventStore: Sendable {
    public let pool: DatabasePool

    public init(url: URL, readOnly: Bool = false) throws {
        var cfg = Configuration()
        cfg.readonly = readOnly
        // Writers need the busy timeout MORE than readers: brain CLI / MCP /
        // subprocesses may hold snapshots while the app writes.
        cfg.busyMode = .timeout(5.0)
        pool = try DatabasePool(path: url.path, configuration: cfg)
        if !readOnly {
            try migrator.migrate(pool)
        }
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull().indexed()
                t.column("source", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("app", .text).indexed()
                t.column("text", .text)
                t.column("payload", .text).notNull()
                t.column("spanId", .integer)
            }
            try db.create(table: "spans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("t0", .double).notNull().indexed()
                t.column("t1", .double).notNull()
                t.column("activity", .text).notNull()
                t.column("app", .text)
                t.column("project", .text)
                t.column("title", .text)
                t.column("entities", .text)
                t.column("evidence", .text)
                t.column("day", .text).notNull().indexed()
            }
            // FTS5 over event text + span titles (external content on events).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE events_fts USING fts5(
                    text, content='events', content_rowid='id', tokenize='unicode61'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER events_ai AFTER INSERT ON events WHEN new.text IS NOT NULL BEGIN
                    INSERT INTO events_fts(rowid, text) VALUES (new.id, new.text);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER events_ad AFTER DELETE ON events WHEN old.text IS NOT NULL BEGIN
                    INSERT INTO events_fts(events_fts, rowid, text) VALUES ('delete', old.id, old.text);
                END
                """)
        }
        return m
    }

    // MARK: - Writes

    public func insert(_ events: [SMEvent]) throws {
        guard !events.isEmpty else { return }
        try pool.write { db in
            for var e in events { try e.insert(db) }
        }
    }

    public func insert(_ span: inout SMSpan) throws {
        // lastInsertedRowID inside the SAME write transaction — a MAX(id)
        // re-read in a separate transaction races concurrent writers.
        span.id = try pool.write { [s = span] db in
            var copy = s
            try copy.insert(db)
            return db.lastInsertedRowID
        }
    }

    // MARK: - Reads

    public func eventCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0 }
    }

    public func search(_ term: String, limit: Int = 20) throws -> [[String: Any]] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.ts, e.source, e.kind, e.app,
                       snippet(events_fts, 0, '«', '»', '…', 12) AS snippet
                FROM events_fts
                JOIN events e ON e.id = events_fts.rowid
                WHERE events_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [FTS5Pattern(matchingAnyTokenIn: term)?.rawPattern ?? term, limit])
            return rows.map { row in
                [
                    "id": row["id"] as Int64? ?? 0,
                    "ts": row["ts"] as Double? ?? 0,
                    "source": row["source"] as String? ?? "",
                    "kind": row["kind"] as String? ?? "",
                    "app": row["app"] as String? ?? "",
                    "snippet": row["snippet"] as String? ?? "",
                ]
            }
        }
    }

    public func spans(day: String) throws -> [SMSpan] {
        try pool.read { db in
            try SMSpan.fetchAll(db, sql: "SELECT * FROM spans WHERE day = ? ORDER BY t0", arguments: [day])
        }
    }

    /// Read-only guarded SQL for the brain CLI (SELECT/WITH only).
    public func rawQuery(_ sql: String, limit: Int = 200) throws -> [[String: Any]] {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("select") || trimmed.hasPrefix("with") else {
            throw NSError(domain: "brain", code: 4, userInfo: [NSLocalizedDescriptionKey: "read-only: SELECT/WITH queries only"])
        }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.prefix(limit).map { row in
                var dict: [String: Any] = [:]
                for (column, value) in row {
                    dict[column] = value.storage.value ?? NSNull()
                }
                return dict
            }
        }
    }

    // MARK: - Brain queue (cursor over meaningful events)

    /// "Meaningful" = worth waking the brain for: real typed text, commits,
    /// pages, messages, commands — NOT focus heartbeats or power snapshots.
    static let meaningfulFilter = """
        ((source = 'input' AND text IS NOT NULL) \
        OR source IN ('git','browser','imessage','mail','shell-history','ide','clipboard','calendar','reminders'))
        """

    public func maxEventId() throws -> Int64 {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id),0) FROM events") ?? 0 }
    }

    public func meaningfulEventCount(sinceId: Int64) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE id > ? AND \(Self.meaningfulFilter)",
                             arguments: [sinceId]) ?? 0
        }
    }

    public func oldestMeaningfulTs(sinceId: Int64) throws -> Double? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT MIN(ts) FROM events WHERE id > ? AND \(Self.meaningfulFilter)",
                                arguments: [sinceId])
        }
    }

    // MARK: - Retention

    /// Delete raw events older than `keepDays`; spans are kept forever (small).
    public func pruneEvents(olderThanDays keepDays: Int) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(keepDays) * 86400
        return try pool.write { db in
            try db.execute(sql: "DELETE FROM events WHERE ts < ?", arguments: [cutoff])
            return db.changesCount
        }
    }
}

// MARK: - Buffered writer (sensors call this; flushes batched)

public actor EventWriter {
    private let store: EventStore
    private var buffer: [SMEvent] = []
    private var flushTask: Task<Void, Never>?
    private let flushThreshold = 200

    public init(store: EventStore) {
        self.store = store
    }

    public func append(_ event: SMEvent) {
        buffer.append(event)
        if buffer.count >= flushThreshold {
            flushNow()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushNow()
            }
        }
    }

    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        do {
            try store.insert(batch)
        } catch {
            SMLog.shared.error("event-writer", "flush-failed", ["count": batch.count, "error": "\(error)"])
        }
    }
}
