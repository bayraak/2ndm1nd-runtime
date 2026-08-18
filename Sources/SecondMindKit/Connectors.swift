// Connectors — scheduled pull sources (native replacements for v1's exporters).
// Each reads a delta since its last run (byte offset / rowid / mtime), appends
// events to the ledger, and persists its own cursor under appData. Run on the
// daily scheduler and via `secondmind connect [name]`.
//
// No-special-permission connectors: shell-history, git, ide, browser(Chrome/
// Arc/Brave). Safari/Messages/Mail need Full Disk Access.

import Foundation

public struct Connectors: Sendable {
    public let config: SMConfig
    public let store: EventStore
    private let statePath: String

    public init(config: SMConfig, store: EventStore) {
        self.config = config
        self.store = store
        self.statePath = config.appData + "/connector-state.json"
    }

    public enum Name: String, Sendable, CaseIterable {
        case shell, git, ide, browser, messages, mail, claudeCode
    }

    @discardableResult
    public func run(_ name: Name) -> Int {
        var state = loadState()
        let n: Int
        switch name {
        case .shell: n = shellHistory(&state)
        case .git: n = gitActivity(&state)
        case .ide: n = ideWorkspaces(&state)
        case .browser: n = browserHistory(&state)
        case .messages: n = messages(&state)
        case .mail: n = mail(&state)
        case .claudeCode: n = claudeConversations(&state)
        }
        saveState(state)
        SMLog.shared.info("connector", "ran", ["connector": name.rawValue, "events": n])
        return n
    }

    @discardableResult
    public func runAll() -> [String: Int] {
        var out: [String: Int] = [:]
        for n in Name.allCases { out[n.rawValue] = run(n) }
        return out
    }

    // MARK: - Shell history (zsh + bash, byte-offset delta)

    private func shellHistory(_ state: inout [String: Any]) -> Int {
        var count = 0
        let home = NSHomeDirectory()
        for (file, shell) in [("\(home)/.zsh_history", "zsh"), ("\(home)/.bash_history", "bash")] {
            guard let data = FileManager.default.contents(atPath: file) else { continue }
            let key = "shell_offset_\(shell)"
            var offset = state[key] as? Int ?? max(0, data.count - 20000) // first run: last ~20KB
            if offset > data.count { offset = 0 } // file shrank (rotation)
            guard offset < data.count else { continue }
            let slice = data.subdata(in: offset..<data.count)
            let text = String(decoding: slice, as: UTF8.self)
            for raw in text.split(separator: "\n") {
                var cmd = String(raw)
                // zsh extended: ": <ts>:<dur>;<cmd>"
                if cmd.hasPrefix(":"), let semi = cmd.firstIndex(of: ";") {
                    cmd = String(cmd[cmd.index(after: semi)...])
                }
                cmd = cmd.trimmingCharacters(in: .whitespaces)
                guard !cmd.isEmpty else { continue }
                appendEvent(source: "shell-history", kind: "command", app: nil,
                            text: cmd, payload: ["shell": shell, "command": cmd], &count)
            }
            state[key] = data.count
        }
        return count
    }

    // MARK: - Git activity (local repos' reflog HEAD)

    private func gitActivity(_ state: inout [String: Any]) -> Int {
        var count = 0
        let roots = config.fsWatchPaths.filter { $0.contains("/Projects") }
        let searchRoots = roots.isEmpty ? [NSHomeDirectory() + "/Projects"] : roots
        var seen = Set(state["git_seen_sha"] as? [String] ?? [])

        var repos: [String] = []
        for root in searchRoots { findRepos(root, depth: 0, into: &repos) }

        for repo in repos {
            let project = (repo as NSString).lastPathComponent
            // Real commits (not reflog pull/checkout noise) on any LOCAL branch in
            // the last 14 days; dedup by full SHA across runs. --branches (not --all)
            // excludes pulled remote commits; --no-merges keeps it to authored work.
            guard let out = runGit(["-C", repo, "log", "--branches", "--no-merges",
                                    "--since=14.days.ago", "-n", "500",
                                    "--pretty=format:%H\u{1f}%an\u{1f}%at\u{1f}%s"]),
                  !out.isEmpty else { continue }
            for line in out.split(separator: "\n") {
                let f = line.components(separatedBy: "\u{1f}")
                guard f.count == 4, !seen.contains(f[0]) else { continue }
                seen.insert(f[0])
                let ts = Double(f[2]) ?? Date().timeIntervalSince1970
                appendEvent(source: "git", kind: "commit", app: nil, ts: ts,
                            text: "\(project): \(f[3])",
                            payload: ["project": project, "sha": String(f[0].prefix(10)),
                                      "author": f[1], "subject": f[3]], &count)
            }
        }
        state["git_seen_sha"] = Array(seen.suffix(10000))
        return count
    }

    /// Find git repos under a root WITHOUT descending into repos, node_modules, or
    /// hidden dirs. The old recursive enumerator burned its 20k cap on node_modules
    /// and missed most repos (only ~4 events ever captured).
    private func findRepos(_ dir: String, depth: Int, into repos: inout [String]) {
        if depth > 4 { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/.git") { repos.append(dir); return }  // repo → record + prune
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for e in entries where !e.hasPrefix(".") && e != "node_modules" && e != "Library" && e != "Pods" {
            let full = dir + "/" + e
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                findRepos(full, depth: depth + 1, into: &repos)
            }
        }
    }

    /// Run git and return stdout. readDataToEndOfFile before waitUntilExit avoids a
    /// pipe-buffer deadlock on large logs; the watchdog kills a hung process so a
    /// wedged repo can't stall the connectors job forever.
    private func runGit(_ args: [String]) -> String? {
        runProcessCapture(exe: "/usr/bin/git", args: args, timeoutS: 30)
    }

    private func runProcessCapture(exe: String, args: [String], timeoutS: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutS, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0 else {
            SMLog.shared.warn("connector", "subprocess-failed", ["exe": exe, "rc": p.terminationStatus])
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - IDE workspaces (VS Code / Cursor)

    private func ideWorkspaces(_ state: inout [String: Any]) -> Int {
        var count = 0
        let home = NSHomeDirectory()
        for (ide, base) in [("VSCode", "\(home)/Library/Application Support/Code/User/workspaceStorage"),
                            ("Cursor", "\(home)/Library/Application Support/Cursor/User/workspaceStorage")] {
            guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            let lastRun = state["ide_lastrun"] as? Double ?? 0
            for hash in hashes {
                let wj = "\(base)/\(hash)/workspace.json"
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: wj),
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      mtime > lastRun,
                      let data = FileManager.default.contents(atPath: wj),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let folder = (obj["folder"] as? String) ?? (obj["configuration"] as? String) ?? ""
                guard !folder.isEmpty else { continue }
                let project = ((folder.replacingOccurrences(of: "file://", with: "")) as NSString).lastPathComponent
                appendEvent(source: "ide", kind: "workspace-touched", app: ide, ts: mtime,
                            text: project, payload: ["ide": ide, "folder": folder, "project": project], &count)
            }
        }
        state["ide_lastrun"] = Date().timeIntervalSince1970
        return count
    }

    // MARK: - Browser history (Chrome/Arc/Brave via sqlite3 copy)

    private func browserHistory(_ state: inout [String: Any]) -> Int {
        var count = 0
        let home = NSHomeDirectory()
        // Chromium family: µs since 1601-01-01. Query visits since last_visit_time cursor.
        let chromium: [(String, String)] = [
            ("Chrome", "\(home)/Library/Application Support/Google/Chrome/Default/History"),
            ("Arc", "\(home)/Library/Application Support/Arc/User Data/Default/History"),
            ("Brave", "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/History"),
        ]
        for (name, db) in chromium where FileManager.default.fileExists(atPath: db) {
            let key = "browser_\(name)_ts"
            let cursor = state[key] as? Int ?? 0 // chromium µs
            let sql = """
                SELECT urls.url, urls.title, visits.visit_time
                FROM visits JOIN urls ON urls.id = visits.url
                WHERE visits.visit_time > \(cursor)
                ORDER BY visits.visit_time DESC LIMIT 500;
                """
            var maxTs = cursor
            for row in querySQLite(db: db, sql: sql) {
                let cols = row.components(separatedBy: "\u{1f}")
                guard cols.count >= 3, let vt = Int(cols[2]) else { continue }
                maxTs = max(maxTs, vt)
                let epoch = Double(vt) / 1_000_000 - 11_644_473_600 // µs since 1601 → unix
                appendEvent(source: "browser", kind: "visit", app: name, ts: epoch,
                            text: "\(cols[1]) — \(cols[0])",
                            payload: ["browser": name, "url": cols[0], "title": cols[1]], &count)
            }
            state[key] = maxTs
        }
        return count
    }

    // MARK: - Messages (chat.db, rowid delta) — REQUIRES Full Disk Access

    private func messages(_ state: inout [String: Any]) -> Int {
        var count = 0
        let db = NSHomeDirectory() + "/Library/Messages/chat.db"
        guard FileManager.default.fileExists(atPath: db) else { return 0 }
        if !FileManager.default.isReadableFile(atPath: db) {
            SMLog.shared.warn("connector", "messages-fda-denied", [
                "hint": "System Settings → Privacy & Security → Full Disk Access → enable 2ndm1nd",
            ])
            return 0
        }
        let lastRowid = state["messages_rowid"] as? Int ?? 0
        // ns-since-2001 (modern) or seconds (legacy) date; handle both. is_from_me,
        // handle id, chat name, legacy text + attributedBody length.
        let sql = """
            SELECT m.ROWID,
                   CASE WHEN m.date > 1000000000000000 THEN m.date/1000000000 + 978307200 ELSE m.date + 978307200 END,
                   COALESCE(h.id,''), m.is_from_me,
                   REPLACE(REPLACE(COALESCE(m.text,''), char(10),' '), char(31),' ')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > \(lastRowid)
            ORDER BY m.ROWID LIMIT 500;
            """
        var maxRowid = lastRowid
        for row in querySQLite(db: db, sql: sql) {
            let cols = row.components(separatedBy: "\u{1f}")
            guard cols.count >= 5, let rowid = Int(cols[0]), let ts = Double(cols[1]) else { continue }
            maxRowid = max(maxRowid, rowid)
            let fromMe = cols[3] == "1"
            let handle = cols[2]
            let text = cols[4]
            appendEvent(source: "imessage", kind: fromMe ? "sent" : "received", app: nil, ts: ts,
                        text: text.isEmpty ? nil : "\(fromMe ? "→" : "←") \(handle): \(text)",
                        payload: ["handle": handle, "from_me": fromMe, "text": text], &count)
        }
        state["messages_rowid"] = maxRowid
        return count
    }

    // MARK: - Mail (raw email + attachments surfaced by path, .emlx fs delta) — needs FDA
    //
    // We do NO content parsing / OCR / distillation — the brain reads and understands
    // the files itself (user directive). The connector is a dumb pipe: it COPIES the raw
    // `.emlx` and its pre-extracted `Attachments/<rowid>/` OUT to a claude-readable dir
    // (Mail is FDA-gated, so the sandboxed brain can't read them in place) and stores the
    // PATHS, plus cheap From/Subject/Date from the Envelope Index (metadata query, no file
    // reads). Mail CONTENT is ledger-only — never the vault (brain rule). Delta by .emlx
    // mtime: `mail_hi` walks new mail forward; `mail_lo` backfills history a bounded
    // batch/run until `mail_backfill_done`, then steady-state uses cheap `find -newer`.

    private func mail(_ state: inout [String: Any]) -> Int {
        let mailRoot = NSHomeDirectory() + "/Library/Mail"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: mailRoot),
              let vdir = versions.filter({ $0.hasPrefix("V") }).sorted().last else { return 0 }
        // FDA probe: Envelope Index present but unreadable => grant missing.
        let envIndex = mailRoot + "/" + vdir + "/MailData/Envelope Index"
        if FileManager.default.fileExists(atPath: envIndex), !FileManager.default.isReadableFile(atPath: envIndex) {
            SMLog.shared.warn("connector", "mail-fda-denied",
                ["hint": "System Settings → Privacy & Security → Full Disk Access → enable 2ndm1nd"])
            return 0
        }

        let backfillDone = state["mail_backfill_done"] as? Bool ?? false
        // Enumerate message files with mtime. Once backfill is done, only look at
        // files newer than the watermark (cheap `find -newer`) instead of all ~100k.
        let findExpr = "\\( -name '*.emlx' -o -name '*.partial.emlx' \\)"
        var cmd = "find '\(mailRoot)' -type f \(findExpr) -print0 | xargs -0 stat -f '%m\t%N' 2>/dev/null"
        if backfillDone, let hi = state["mail_hi"] as? Double, hi > 0 {
            let ref = config.appData + "/.mailref"
            _ = runProcessCapture(exe: "/bin/sh", args: ["-c",
                "touch -t $(date -r \(Int(hi)) +%Y%m%d%H%M.%S) '\(ref)'"], timeoutS: 10)
            cmd = "find '\(mailRoot)' -type f \(findExpr) -newer '\(ref)' -print0 | xargs -0 stat -f '%m\t%N' 2>/dev/null"
        }
        let listing = runProcessCapture(exe: "/bin/sh", args: ["-c", cmd], timeoutS: 120) ?? ""

        // rowid -> newest (mtime, path); prefer full `.emlx` over `.partial.emlx`.
        var byRowid: [String: (mtime: Double, path: String, partial: Bool)] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let mt = Double(parts[0]) else { continue }
            let file = (parts[1] as NSString).lastPathComponent
            let partial = file.hasSuffix(".partial.emlx")
            let rowid = file.replacingOccurrences(of: ".partial.emlx", with: "")
                            .replacingOccurrences(of: ".emlx", with: "")
            if let ex = byRowid[rowid], !ex.partial { continue }
            byRowid[rowid] = (mt, parts[1], partial)
        }
        if byRowid.isEmpty { return 0 }

        let all = byRowid.map { (rowid: $0.key, mtime: $0.value.mtime, path: $0.value.path) }
        let globalMax = all.map { $0.mtime }.max() ?? 0
        let hi = state["mail_hi"] as? Double ?? globalMax   // first run: watermark = newest (no giant burst)

        var pick = all.filter { $0.mtime > hi }             // forward: new/changed mail (small in steady state)
        var newLo = state["mail_lo"] as? Double ?? (globalMax + 1)
        if !backfillDone {
            let older = all.filter { $0.mtime < newLo }.sorted { $0.mtime > $1.mtime }  // newest-first below lo
            let batch = Array(older.prefix(800))
            pick.append(contentsOf: batch)
            if let last = batch.last { newLo = last.mtime }
            if older.count <= 800 { state["mail_backfill_done"] = true }               // nothing older left
        }
        if pick.isEmpty { state["mail_hi"] = max(hi, globalMax); return 0 }

        let meta = mailMeta(envIndex: envIndex, rowids: pick.map { $0.rowid })
        let mailOut = config.appData + "/mail"
        var count = 0
        for item in pick {
            let dest = mailOut + "/" + item.rowid
            try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            // Copy the raw email VERBATIM — the brain reads/parses it (no distill/OCR here).
            let emailDest = dest + "/message.emlx"
            if !FileManager.default.fileExists(atPath: emailDest) {
                try? FileManager.default.copyItem(atPath: item.path, toPath: emailDest)
            }
            // Copy its attachments VERBATIM beside it.
            let dataDir = ((item.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let attachPaths = copyMailAttachments(srcDir: dataDir + "/Attachments/" + item.rowid, destDir: dest)
            let m = meta[item.rowid] ?? [:]
            let from = m["sender"] ?? ""
            let subject = m["subject"] ?? ""
            let dateStr = m["date"] ?? ""
            let ts = Double(m["ts"] ?? "") ?? item.mtime
            var text = "From: \(from)\nSubject: \(subject)\n\u{1F4E7} \(emailDest)"
            for a in attachPaths { text += "\n\u{1F4CE} \(a)" }
            appendEvent(source: "mail", kind: "message", app: nil, ts: ts, text: text,
                        payload: ["from": from, "subject": subject, "date": dateStr,
                                  "rowid": item.rowid, "email_path": emailDest, "attachments": attachPaths], &count)
        }
        state["mail_hi"] = max(hi, globalMax)
        if !backfillDone { state["mail_lo"] = newLo }
        return count
    }

    /// From/Subject/Date for a batch of message ROWIDs, straight from the Envelope Index
    /// (metadata query only — no file reads/parsing/OCR; the brain reads the raw files).
    /// The `.emlx` filename IS the Envelope Index ROWID. Returns rowid -> {sender,subject,ts,date}.
    private func mailMeta(envIndex: String, rowids: [String]) -> [String: [String: String]] {
        let idList = rowids.compactMap { Int($0) }.map(String.init).joined(separator: ",")
        guard !idList.isEmpty else { return [:] }
        let sql = """
            SELECT m.ROWID, COALESCE(a.address,''),
                   REPLACE(REPLACE(COALESCE(s.subject,''), char(10),' '), char(9),' '),
                   m.date_received, datetime(m.date_received,'unixepoch','localtime')
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE m.ROWID IN (\(idList));
            """
        var out: [String: [String: String]] = [:]
        for row in querySQLite(db: envIndex, sql: sql) {
            let c = row.components(separatedBy: "\u{1f}")
            guard c.count >= 5 else { continue }
            out[c[0]] = ["sender": c[1], "subject": c[2], "ts": c[3], "date": c[4]]
        }
        return out
    }

    /// Copy a message's pre-extracted attachment files OUT to a claude-readable dir (Mail
    /// is FDA-gated). No parsing — verbatim copy so the brain reads them. Returns dest paths.
    private func copyMailAttachments(srcDir: String, destDir: String) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: srcDir, isDirectory: &isDir), isDir.boolValue,
              let items = fm.enumerator(atPath: srcDir) else { return [] }
        var dests: [String] = []
        for case let rel as String in items {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: srcDir + "/" + rel, isDirectory: &d), !d.boolValue else { continue }
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            var dest = destDir + "/" + (rel as NSString).lastPathComponent
            if fm.fileExists(atPath: dest) { dest = destDir + "/" + rel.replacingOccurrences(of: "/", with: "_") }
            if !fm.fileExists(atPath: dest) { try? fm.copyItem(atPath: srcDir + "/" + rel, toPath: dest) }
            if fm.fileExists(atPath: dest) { dests.append(dest) }
        }
        return dests
    }

    private func querySQLite(db: String, sql: String) -> [String] {
        // Copy first (browser DB is often locked/WAL). Copy the WAL sidecar too
        // when present, or rows sitting un-checkpointed are invisible to us.
        let tmp = config.appData + "/.\(UUID().uuidString).db"
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suffix) }
        }
        guard (try? FileManager.default.copyItem(atPath: db, toPath: tmp)) != nil else { return [] }
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: db + suffix) {
            try? FileManager.default.copyItem(atPath: db + suffix, toPath: tmp + suffix)
        }
        let out = runProcessCapture(exe: "/usr/bin/sqlite3", args: ["-separator", "\u{1f}", tmp, sql], timeoutS: 60)
        return (out ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: - Claude Code conversations (~/.claude/projects/*/*.jsonl)
    //
    // Claude Code stores every session as JSONL. This is the CLEAN Q/A source
    // (vs the input sensor's noisy terminal screen-scrape): the user's real
    // messages to his agents, paired with what the agent said right before —
    // across every project. Delta by message timestamp; first run backfills a
    // few days, then only new turns.

    private func claudeConversations(_ state: inout [String: Any]) -> Int {
        var count = 0
        let root = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return 0 }
        let now = Date().timeIntervalSince1970
        let lastRun = state["claude_lastrun"] as? Double ?? (now - 3 * 86400)  // first run: last 3 days
        let capPerRun = 1200

        for proj in projects {
            let projDir = root + "/" + proj
            guard let files = try? fm.contentsOfDirectory(atPath: projDir) else { continue }
            let projectName = Self.readableProject(proj)
            for file in files where file.hasSuffix(".jsonl") {
                if count >= capPerRun { break }
                let path = projDir + "/" + file
                // Skip sessions untouched since last run (perf: most of 1600+ files are old).
                if let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                   mtime.timeIntervalSince1970 <= lastRun { continue }
                guard let data = fm.contents(atPath: path) else { continue }
                // Never ingest the brain's OWN `claude -p` sessions (feedback loop):
                // a brain transcript always OPENS with the sentinel boot prompt as its
                // first real user turn. A real chat never does — the token only appears
                // buried in quoted tool output later — so a first-turn check drops the
                // brain's self-talk without nuking sessions that merely discuss it.
                if Self.isBrainSessionFile(data) { continue }
                var lastAssistant = ""
                for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    if count >= capPerRun { break }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          let role = msg["role"] as? String else { continue }
                    let text = Self.extractText(msg["content"])
                    guard !text.isEmpty else { continue }
                    if role == "assistant" { lastAssistant = text; continue }
                    guard role == "user",
                          let ts = Self.parseISO(obj["timestamp"] as? String), ts > lastRun,
                          Self.isRealUserPrompt(text) else { continue }
                    let q = String(lastAssistant.suffix(800))
                    let a = String(text.prefix(4000))
                    appendEvent(source: "claude-code", kind: "qa-exchange", app: projectName, ts: ts,
                                text: "Q: \(q)\nA: \(a)",
                                payload: ["project": projectName,
                                          "session": String(file.dropLast(6)), "q_len": q.count], &count)
                }
            }
        }
        state["claude_lastrun"] = now
        return count
    }

    /// "-Users-you-Projects-2ndm1nd" -> "2ndm1nd" (last path-ish segment).
    private static func readableProject(_ dir: String) -> String {
        let segs = dir.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return segs.last ?? dir
    }

    /// Pull the human text out of a Claude Code content field (string, or an
    /// array of blocks — keep `text` blocks, drop tool_use/tool_result).
    private static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// True if this JSONL is one of the brain's OWN `claude -p` sessions. The brain
    /// boot/resume prompt always leads with the sentinel, and because a day-session
    /// file's FIRST user turn is that boot prompt, checking only the first real user
    /// turn cleanly separates brain self-talk from a real chat that merely quotes the
    /// token in tool output. Deterministic, zero LLM — the thread-aware clean source
    /// stays clean.
    private static func isBrainSessionFile(_ data: Data) -> Bool {
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  msg["role"] as? String == "user" else { continue }
            let text = Self.extractText(msg["content"])
            if text.isEmpty { continue }                       // skip tool-result-only user turns
            return text.hasPrefix("2NDM1ND-BRAIN-SESSION")     // first real user turn is decisive
        }
        return false
    }

    /// Real user prose only — skip system tags, tool results, skill/command
    /// dumps, compaction summaries, and interrupt markers.
    private static func isRealUserPrompt(_ t: String) -> Bool {
        guard t.count >= 2, t.count < 20000 else { return false }
        if t.hasPrefix("<") { return false }                                 // <command-name>, <local-command…>, <bash…>
        if t.hasPrefix("# /") || t.contains("Parse the input below") { return false }  // slash-skill dumps
        if t.hasPrefix("Caveat:") || t.hasPrefix("This session is being continued") { return false }
        if t.hasPrefix("[Request interrupted") || t.hasPrefix("[") && t.count < 60 { return false }
        if t.contains("2NDM1ND-BRAIN-SESSION") { return false }              // the brain's OWN sessions — no feedback loop
        return true
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoFormatterPlain = ISO8601DateFormatter()
    private static func parseISO(_ s: String?) -> Double? {
        guard let s else { return nil }
        return (isoFormatter.date(from: s) ?? isoFormatterPlain.date(from: s))?.timeIntervalSince1970
    }

    // MARK: - Shared helpers

    private func appendEvent(source: String, kind: String, app: String?, ts: Double = Date().timeIntervalSince1970,
                             text: String?, payload: [String: Any], _ count: inout Int) {
        let e = SMEvent(ts: ts, source: source, kind: kind, app: app, text: text, payload: payload)
        do { try store.insert([e]); count += 1 } catch {
            SMLog.shared.error("connector", "insert-failed", ["source": source, "error": "\(error)"])
        }
    }

    private func loadState() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
    private func saveState(_ state: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }
}
