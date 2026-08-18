// Sessionizer — folds raw events into human-meaning ActivitySpans.
// "34 min: coding in my-project (VS Code + Terminal + localhost:9191)"
// Runs periodically; writes spans to SQLite AND to Atlas/AI/spans/<date>.md
// (markdown is the readable surface + what the cortex/curator ingest).
//
// Algorithm: order focus/input events by time; a span is a maximal run where
// the (app-family, project) stays stable with gaps < idle_close_s. Evidence =
// event counts per source in the window; entities = chats/projects touched.

import Foundation
import GRDB

public struct Sessionizer: Sendable {
    public let config: SMConfig
    public let store: EventStore

    public init(config: SMConfig, store: EventStore) {
        self.config = config
        self.store = store
    }

    /// Rebuild spans for a given day (idempotent: clears + rewrites that day).
    @discardableResult
    public func rebuild(day: String) throws -> [SMSpan] {
        let dayStart = Self.dayStart(day)
        let dayEnd = dayStart + 86400

        // Pull the ordering signal: focus snapshots + input activity windows.
        let rows = try store.pool.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT ts, source, kind, app, text, payload FROM events
                WHERE ts >= ? AND ts < ? AND source IN ('focus','input')
                ORDER BY ts
                """, arguments: [dayStart, dayEnd])
        }

        // Decode events into a lightweight timeline first.
        struct Ev { let ts: Double; let source: String; let app: String?; let activity: String; let project: String?; let entity: String? }
        let timeline: [Ev] = rows.map { row in
            let app = row["app"] as String?
            let payloadStr = row["payload"] as String? ?? "{}"
            let payload = (try? JSONSerialization.jsonObject(with: Data(payloadStr.utf8))) as? [String: Any] ?? [:]
            let family = (payload["family"] as? String) ?? FocusContext.family(of: app ?? "")
            let project = (payload["project"] as? String) ?? (payload["terminal_cwd"] as? String).map { ($0 as NSString).lastPathComponent }
            return Ev(ts: row["ts"] as Double? ?? 0, source: row["source"] as String? ?? "",
                      app: app, activity: OpenSpan.activityName(family: family),
                      project: project, entity: (payload["chat"] as? String) ?? project)
        }

        var spans: [SMSpan] = []
        var cur: OpenSpan? = nil
        let idle = Double(config.spanIdleCloseS)

        // Continuity is by ACTIVITY (coding/browsing/…), so Terminal↔VSCode
        // stays one "coding" span. Each event extends the span's end toward the
        // NEXT event (the user was "in" it until they switched), capped at idle.
        for (i, ev) in timeline.enumerated() {
            let nextTs = i + 1 < timeline.count ? timeline[i + 1].ts : ev.ts
            let dwell = min(max(0, nextTs - ev.ts), idle)   // fill-to-next, capped
            let evEnd = ev.ts + dwell

            if var open = cur {
                let sameActivity = open.activity == ev.activity
                if ev.ts - open.lastTs <= idle && sameActivity {
                    open.extendTo(end: evEnd, source: ev.source, app: ev.app, entity: ev.entity, project: ev.project)
                    cur = open
                    continue
                } else {
                    spans.append(open.close())
                }
            }
            var open = OpenSpan(t0: ev.ts, activity: ev.activity, app: ev.app, project: ev.project, entity: ev.entity)
            open.extendTo(end: evEnd, source: ev.source, app: ev.app, entity: ev.entity, project: ev.project)
            cur = open
        }
        if let open = cur { spans.append(open.close()) }
        // Drop noise: spans < 30s that carry no entity/project.
        spans = spans.filter { ($0.t1 - $0.t0) >= 30 || !($0.project ?? "").isEmpty || ($0.entities ?? "[]") != "[]" }

        // Persist: clear day, insert fresh.
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM spans WHERE day = ?", arguments: [day])
        }
        for i in spans.indices {
            try store.insert(&spans[i])
        }

        try writeMarkdown(day: day, spans: spans)
        SMLog.shared.info("sessionizer", "rebuilt", ["day": day, "spans": spans.count, "events": rows.count])
        return spans
    }

    // MARK: - Markdown surface

    private func writeMarkdown(day: String, spans: [SMSpan]) throws {
        let dir = config.vault + "/Atlas/AI/spans"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(day).md"

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        var lines: [String] = [
            "---", "type: activity-spans", "day: \(day)",
            "generated_at: \(Self.iso(Date()))", "---", "",
            "# Activity — \(day)", "",
        ]
        if spans.isEmpty {
            lines.append("_No activity spans recorded._")
        }
        for s in spans {
            let start = tf.string(from: Date(timeIntervalSince1970: s.t0))
            let end = tf.string(from: Date(timeIntervalSince1970: s.t1))
            let mins = max(1, Int((s.t1 - s.t0) / 60))
            let ctx = [s.project, s.app].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("- **\(start)–\(end)** (\(mins)m) — \(s.activity)\(ctx.isEmpty ? "" : ": \(ctx)")")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    static func dayStart(_ day: String) -> Double {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let d = f.date(from: day) else { return 0 }
        return cal.startOfDay(for: d).timeIntervalSince1970
    }

    static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

private struct OpenSpan {
    let t0: Double
    var lastTs: Double
    var endTs: Double
    let activity: String
    var app: String?
    var project: String?
    var sources: [String: Int] = [:]
    var apps: [String: Int] = [:]
    var entities: Set<String> = []

    init(t0: Double, activity: String, app: String?, project: String?, entity: String?) {
        self.t0 = t0
        self.lastTs = t0
        self.endTs = t0
        self.activity = activity
        self.app = app
        self.project = project
        if let entity, !entity.isEmpty { entities.insert(entity) }
    }

    mutating func extendTo(end: Double, source: String, app: String?, entity: String?, project: String?) {
        lastTs = max(lastTs, end)  // last event time (for idle gap checks)
        endTs = max(endTs, end)
        sources[source, default: 0] += 1
        if let app { apps[app, default: 0] += 1 }
        if let entity, !entity.isEmpty { entities.insert(entity) }
        // Prefer a concrete project/app once we see one.
        if self.project == nil || self.project?.isEmpty == true, let project, !project.isEmpty { self.project = project }
    }

    func close() -> SMSpan {
        // Dominant app = most-seen bundle id in the span.
        let domApp = apps.max(by: { $0.value < $1.value })?.key ?? app
        return SMSpan(
            t0: t0, t1: max(endTs, t0 + 1),
            activity: activity,
            app: domApp, project: project,
            title: nil,
            entities: Array(entities),
            evidence: sources
        )
    }

    static func activityName(family: String) -> String {
        switch family {
        case "ide", "terminal": "coding"
        case "chat": "chatting"
        case "browser": "browsing"
        case "notes": "note-taking"
        default: "using \(family)"
        }
    }
}
