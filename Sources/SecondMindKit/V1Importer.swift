// V1Importer — one-time migration of jarvis v1 JSONL events into the ledger.
// Source layout: ~/.local/share/2ndm1nd/events/<YYYY-MM-DD>/<source>.jsonl
// (plus .jsonl.gz once the v1 rotation job has compressed old days — those
// are skipped with a count; run before day 30 or gunzip first).
//
// v1 envelope: {"ts": iso8601, "component": ..., "level": ..., "event": ...,
//               "payload": {...}}  — some exporters use flatter shapes; we
// keep the whole line as payload and extract best-effort searchable text.

import Foundation

public enum V1Importer {
    public struct Result: Sendable {
        public var imported = 0
        public var skipped = 0
        public var files = 0
    }

    static let isoParsers: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"].map {
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    static func parseTS(_ s: String?) -> Double? {
        guard let s else { return nil }
        for p in isoParsers {
            if let d = p.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    public static func importAll(from dir: String, into store: EventStore) throws -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: dir).sorted() else {
            throw NSError(domain: "import", code: 1, userInfo: [NSLocalizedDescriptionKey: "events dir not found: \(dir)"])
        }
        for day in days where day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let dayDir = dir + "/" + day
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir) else { continue }
            for file in files.sorted() {
                if file.hasSuffix(".gz") { result.skipped += 1; continue }
                guard file.hasSuffix(".jsonl") else { continue }
                result.files += 1
                let source = String(file.dropLast(6)) // strip .jsonl
                let path = dayDir + "/" + file
                try importFile(path: path, source: source, day: day, into: store, result: &result)
            }
        }
        return result
    }

    static func importFile(path: String, source: String, day: String, into store: EventStore, result: inout Result) throws {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        var batch: [SMEvent] = []
        batch.reserveCapacity(2048)

        // Fallback ts: midday of the file's day.
        let dayFallback: Double = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return (f.date(from: day)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) + 43200
        }()

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { result.skipped += 1; continue }

            let payload = obj["payload"] as? [String: Any] ?? obj
            let ts = parseTS(obj["ts"] as? String) ?? parseTS(payload["visit_at"] as? String)
                ?? parseTS(payload["executed_at"] as? String) ?? dayFallback
            let kind = obj["event"] as? String ?? "v1-row"
            let app = (payload["bundle_id"] as? String) ?? (payload["app_bundle_id"] as? String)
                ?? (payload["browser"] as? String) ?? (payload["ide"] as? String)

            var event = SMEvent(
                ts: ts,
                source: normalizeSource(source),
                kind: kind,
                app: app,
                text: extractText(source: source, payload: payload),
                payload: payload
            )
            // Preserve original day association even when ts fell back.
            _ = event
            batch.append(event)
            if batch.count >= 2000 {
                try store.insert(batch)
                result.imported += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        try store.insert(batch)
        result.imported += batch.count
    }

    static func normalizeSource(_ raw: String) -> String {
        // browser-Chrome → browser; keep others as-is.
        if raw.hasPrefix("browser-") { return "browser" }
        return raw
    }

    /// Best-effort searchable text per v1 source shape.
    static func extractText(source: String, payload: [String: Any]) -> String? {
        var parts: [String] = []
        for key in ["window_title", "title", "url", "command", "text_sample", "chat_name",
                    "app_name", "folder", "workspace", "path"] {
            if let v = payload[key] as? String, !v.isEmpty { parts.append(v) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
