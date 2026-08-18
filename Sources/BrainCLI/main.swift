// brain — CLI into the 2ndMind ledger. The tool headless Claude uses to query
// the SQLite event store (and humans, for debugging). All output is JSON.
//
//   brain search <term> [--limit N]      FTS5 over event text
//   brain spans [--date YYYY-MM-DD]      activity spans for a day
//   brain query "SELECT ..."             read-only SQL (SELECT/WITH only)
//   brain stats                          row counts + freshness
//   brain import-v1 [--dir PATH]         one-time v1 JSONL import

import Foundation
import SecondMindKit

let BRAIN_VERSION = "0.2.0"

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("brain: \(msg)\n".utf8))
    exit(code)
}

func emitJSON(_ obj: Any) {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    else { fail("failed to serialize output") }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

/// Extract `--name value`, removing both tokens from `args`.
func takeFlag(_ name: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func spanDict(_ s: SMSpan) -> [String: Any] {
    var d: [String: Any] = [:]
    d["id"] = s.id ?? 0
    d["t0"] = s.t0
    d["t1"] = s.t1
    d["minutes"] = Int((s.t1 - s.t0) / 60)
    d["activity"] = s.activity
    d["app"] = s.app ?? ""
    d["project"] = s.project ?? ""
    d["title"] = s.title ?? ""
    d["entities"] = s.entities ?? "[]"
    return d
}

func runBrain(_ argv: [String]) {
    var args = argv
    guard let cmd = args.first else {
        print("""
        brain \(BRAIN_VERSION) — query the 2ndMind ledger
        usage: brain search <term> [--limit N]
               brain spans [--date YYYY-MM-DD]
               brain query "SELECT ..."
               brain stats
               brain annotate <event_id> <key> <value> [--by who]
               brain annotations [--event ID] [--key K] [--limit N]
               brain import-v1 [--dir PATH]
        """)
        exit(0)
    }
    args.removeFirst()

    if cmd == "--version" || cmd == "version" {
        print("brain \(BRAIN_VERSION)")
        exit(0)
    }

    let config = SMConfig.load()
    do {
        switch cmd {
        case "stats":
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            let counts = try store.rawQuery("""
                SELECT (SELECT COUNT(*) FROM events) AS events,
                       (SELECT COUNT(*) FROM spans)  AS spans,
                       (SELECT MAX(ts) FROM events)  AS latest_event_ts
                """)
            emitJSON(counts.first ?? [:])

        case "search":
            let limit = Int(takeFlag("--limit", &args) ?? "20") ?? 20
            guard let term = args.first, !term.isEmpty else { fail("usage: brain search <term>", code: 2) }
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            emitJSON(try store.search(term, limit: limit))

        case "spans":
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let day = takeFlag("--date", &args) ?? f.string(from: Date())
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            let spans = try store.spans(day: day)
            let out: [[String: Any]] = spans.map(spanDict)
            emitJSON(out)

        case "query":
            let limit = Int(takeFlag("--limit", &args) ?? "200") ?? 200
            guard let sql = args.first else { fail("usage: brain query \"SELECT ...\"", code: 2) }
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            emitJSON(try store.rawQuery(sql, limit: limit))

        // ANNOTATE (2026-08-05) — the brain's write-back channel, and deliberately
        // the ONLY one. Capture-time labels (`to`, `channel`) are provisional: a
        // window title is all the sensor can see, so a browser-hosted chat records
        // a conversation with no name on it. The brain resolves those at SLEEP from
        // the raw evidence it already has, and records the resolution HERE.
        //
        // Insert-only, and in a SEPARATE file (annotations.db) — the raw ledger stays
        // append-only and verbatim by construction, not by trusting a model never to
        // issue an UPDATE. Corrections supersede, never overwrite; every row carries
        // who made it, so a wrong resolution is visible and reversible rather than
        // silently baked into history.
        case "annotate":
            let by = takeFlag("--by", &args) ?? "brain"
            guard args.count >= 3, let eventID = Int64(args[0]) else {
                fail("usage: brain annotate <event_id> <key> <value> [--by who]", code: 2)
            }
            let key = args[1], value = args[2...].joined(separator: " ")
            emitJSON(try Annotations.add(eventID: eventID, key: key, value: value, by: by))

        case "annotations":
            let limit = Int(takeFlag("--limit", &args) ?? "500") ?? 500
            let key = takeFlag("--key", &args)
            let eventID = takeFlag("--event", &args).flatMap(Int64.init)
            emitJSON(try Annotations.list(eventID: eventID, key: key, limit: limit))

        case "import-v1":
            let dir = takeFlag("--dir", &args) ?? (NSHomeDirectory() + "/.local/share/2ndm1nd/events")
            let store = try EventStore(url: config.ledgerURL)
            let r = try V1Importer.importAll(from: dir, into: store)
            emitJSON(["imported": r.imported, "skipped": r.skipped, "files": r.files])

        default:
            fail("unknown command '\(cmd)'", code: 2)
        }
    } catch {
        fail("\(error.localizedDescription)")
    }
}

runBrain(Array(CommandLine.arguments.dropFirst()))
