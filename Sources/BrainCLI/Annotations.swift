// Annotations — a sidecar, insert-only store for the brain's RESOLUTIONS of what
// capture could only record provisionally.
//
// Why a separate file and not a column on `events`:
//   • the ledger is the verbatim record of what happened. Interpretation changes;
//     observation must not. Keeping them in one table means every improvement to
//     interpretation rewrites history, and then "what did he actually type" has no
//     answer that survives the next idea.
//   • the cortex sandbox leaves the app-data directory writable (the WAL sidecar
//     needs it), so the model *could* open brain.db and UPDATE it. Putting the write
//     surface in its own file behind an insert-only verb makes the raw ledger safe by
//     construction rather than by hoping the model never tries.
//
// Supersede, never overwrite: re-annotating the same (event, key) appends a newer row.
// Readers take the latest. Nothing is ever destroyed, so a wrong resolution is a
// visible diff rather than a silent rewrite.

import Foundation
import GRDB

enum Annotations {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("2ndMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("annotations.db")
    }

    private static func pool() throws -> DatabaseQueue {
        var cfg = Configuration()
        cfg.busyMode = .timeout(5)
        let q = try DatabaseQueue(path: url.path, configuration: cfg)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS annotations (
                    id       INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id INTEGER NOT NULL,
                    key      TEXT    NOT NULL,
                    value    TEXT    NOT NULL,
                    by       TEXT    NOT NULL DEFAULT 'brain',
                    ts       REAL    NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_ann_event ON annotations(event_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_ann_key   ON annotations(key)")
        }
        return q
    }

    @discardableResult
    static func add(eventID: Int64, key: String, value: String, by: String) throws -> [String: Any] {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !value.isEmpty else {
            throw NSError(domain: "annotate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "key and value must be non-empty"])
        }
        let ts = Date().timeIntervalSince1970
        let id = try pool().write { db -> Int64 in
            try db.execute(sql: "INSERT INTO annotations (event_id,key,value,by,ts) VALUES (?,?,?,?,?)",
                           arguments: [eventID, k, value, by, ts])
            return db.lastInsertedRowID
        }
        return ["id": id, "event_id": eventID, "key": k, "value": value, "by": by, "ts": ts]
    }

    /// Latest value per (event, key) — supersession resolved for the reader.
    static func list(eventID: Int64?, key: String?, limit: Int) throws -> [[String: Any]] {
        var sql = """
            SELECT a.event_id, a.key, a.value, a.by, a.ts FROM annotations a
            JOIN (SELECT event_id, key, MAX(id) mid FROM annotations GROUP BY event_id, key) l
              ON a.id = l.mid
            """
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        if let eventID { clauses.append("a.event_id = ?"); args.append(eventID) }
        if let key { clauses.append("a.key = ?"); args.append(key) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY a.ts DESC LIMIT \(max(1, limit))"
        return try pool().read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                ["event_id": row["event_id"] as Int64? ?? 0,
                 "key": row["key"] as String? ?? "",
                 "value": row["value"] as String? ?? "",
                 "by": row["by"] as String? ?? "",
                 "ts": row["ts"] as Double? ?? 0]
            }
        }
    }
}
