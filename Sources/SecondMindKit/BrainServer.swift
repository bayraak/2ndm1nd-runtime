// BrainServer — localhost HTTP surface for Raycast / MCP / scripts.
// Dependency-free (Network.framework, no external package) to keep the core
// Node/Docker-free. Bearer token in a 0600 file; binds 127.0.0.1 only.
//
//   GET /health
//   GET /now                    → Atlas/AI/Now.md
//   GET /spans?date=YYYY-MM-DD  → today's spans (JSON)
//   GET /search?q=term&limit=N  → FTS5 search (JSON)
//   POST /ask  {"q": "..."}     → agentic Cortex answer (JSON)

import Foundation
import Network

public final class BrainServer: @unchecked Sendable {
    private let config: SMConfig
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "brainserver", attributes: .concurrent)
    // One long-lived read-only pool for all requests (a fresh SQLite pool per
    // HTTP request leaked FDs and burned latency).
    private let roStore: EventStore?

    public init(config: SMConfig) {
        self.config = config
        self.token = BrainServer.loadOrCreateToken()
        self.roStore = try? EventStore(url: config.ledgerURL, readOnly: true)
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config.serverPort))!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        SMLog.shared.info("brain-server", "started", ["port": config.serverPort])
    }

    public func stop() { listener?.cancel() }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            // Have we got the full headers (and body, for our small POSTs)?
            if let headerEnd = Self.range(of: "\r\n\r\n", in: buf) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let contentLength = Self.contentLength(head)
                let bodyStart = headerEnd.upperBound
                let have = buf.count - bodyStart
                if have >= contentLength {
                    let body = String(decoding: buf[bodyStart..<(bodyStart + contentLength)], as: UTF8.self)
                    self.respond(conn, head: head, body: body)
                    return
                }
            }
            if error != nil || isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: String, body: String) {
        let lines = head.split(separator: "\r\n")
        guard let requestLine = lines.first else { return send(conn, status: 400, json: ["error": "bad request"]) }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 2 else { return send(conn, status: 400, json: ["error": "bad request"]) }
        let method = String(comps[0])
        let target = String(comps[1])
        let (path, query) = Self.splitPath(target)

        // Auth (except /health).
        if path != "/health" {
            let auth = Self.headerValue("Authorization", in: lines)
            guard auth == "Bearer \(token)" else {
                return send(conn, status: 401, json: ["error": "unauthorized"])
            }
        }

        switch (method, path) {
        case ("GET", "/health"):
            send(conn, status: 200, json: ["ok": true, "service": "2ndm1nd", "port": config.serverPort])

        case ("GET", "/now"):
            let text = (try? String(contentsOfFile: config.vault + "/Atlas/AI/Now.md", encoding: .utf8)) ?? "(no Now.md yet)"
            send(conn, status: 200, json: ["now": text])

        case ("GET", "/spans"):
            let day = query["date"] ?? Cortex.today()
            guard let store = roStore else { return send(conn, status: 500, json: ["error": "ledger unavailable"]) }
            do {
                let spans = try store.spans(day: day).map { s -> [String: Any] in
                    ["t0": s.t0, "t1": s.t1, "minutes": Int((s.t1 - s.t0) / 60),
                     "activity": s.activity, "app": s.app ?? "", "project": s.project ?? ""]
                }
                send(conn, status: 200, json: ["day": day, "spans": spans])
            } catch { send(conn, status: 500, json: ["error": "\(error)"]) }

        case ("GET", "/search"):
            guard let q = query["q"], !q.isEmpty else { return send(conn, status: 400, json: ["error": "missing q"]) }
            guard let store = roStore else { return send(conn, status: 500, json: ["error": "ledger unavailable"]) }
            let limit = Int(query["limit"] ?? "20") ?? 20
            do {
                send(conn, status: 200, json: ["query": q, "results": try store.search(q, limit: limit)])
            } catch { send(conn, status: 500, json: ["error": "\(error)"]) }

        case ("POST", "/ask"):
            let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let q = obj?["q"] as? String, !q.isEmpty else { return send(conn, status: 400, json: ["error": "missing q"]) }
            // Route through the on-demand cortex tier (agentic, read-only). Async.
            Task { [config] in
                do {
                    let runner = ClaudeRunner(config: config, component: "brain-ask")
                    let result = try await runner.run(
                        prompt: Cortex.prompt(.ondemand, vault: config.vault),
                        context: "USER QUESTION:\n\(q)",
                        mode: .tools(allowed: ["Read", "Grep", "Glob", "Bash"], workdir: config.vault),
                        gated: false   // user-initiated — don't queue behind the brain tick
                    )
                    self.send(conn, status: 200, json: ["q": q, "answer": result.output])
                } catch {
                    self.send(conn, status: 500, json: ["error": "\(error)"])
                }
            }

        default:
            send(conn, status: 404, json: ["error": "not found", "path": path])
        }
    }

    // MARK: - Response

    private func send(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let statusText = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(bodyData)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Parsing helpers

    static func range(of needle: String, in data: Data) -> Range<Data.Index>? {
        data.range(of: Data(needle.utf8))
    }
    static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
    static func headerValue(_ name: String, in lines: [Substring]) -> String? {
        for line in lines where line.lowercased().hasPrefix(name.lowercased() + ":") {
            return line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    static func splitPath(_ target: String) -> (String, [String: String]) {
        guard let qIdx = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIdx])
        var query: [String: String] = [:]
        for pair in target[target.index(after: qIdx)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return (path, query)
    }

    // MARK: - Token (0600 file)

    public var authToken: String { token }

    static func loadOrCreateToken() -> String {
        let tokenPath = NSHomeDirectory() + "/Library/Application Support/2ndMind/server-token"
        if let existing = try? String(contentsOfFile: tokenPath, encoding: .utf8), !existing.isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let token = UUID().uuidString + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? FileManager.default.createDirectory(
            atPath: (tokenPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        // Lock it down (0600).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
        return token
    }
}
