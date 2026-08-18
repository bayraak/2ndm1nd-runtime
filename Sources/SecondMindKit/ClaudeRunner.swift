// ClaudeRunner — every Anthropic call in 2ndMind goes through here.
//
// Subscription auth via the Claude Code CLI (`claude -p`). Hard rules learned
// in v1 (see feedback_jarvis_native_claude_not_node_shim):
//   • ALWAYS prefer the self-contained native binary (~/.local/bin/claude —
//     a Bun single-file executable, no external Node). The Homebrew shim is a
//     `#!/usr/bin/env node` script that crashes under Node ≥26.
//   • Stripped env contract: HOME + USER + LOGNAME + PATH, nothing else, and
//     ANTHROPIC_API_KEY is forcibly absent so subscription auth is the only path.
//   • Prompt goes via stdin (never argv — ARG_MAX).
//
// OBSERVER CONTRACT (user directive 2026-07-11): every claude -p call runs with
// --permission-mode bypassPermissions (no approval walls, ever) AND is read-only
// by construction — enforced at three layers:
//   1. sandbox-exec: the OS denies file-writes to the vault + never_record_paths
//      for claude AND everything it spawns (Bash children included).
//   2. --disallowedTools strips Write/Edit/Notebook/web tools in .tools mode.
//   3. --safe-mode + --strict-mcp-config: no hooks, no MCP servers, no user
//      customizations leak into headless runs (also keeps them fast).
// The model NEVER mutates the vault. It proposes writes as <<<WRITE path>>>
// blocks in its output; Cortex applies them inside a whitelist (see Cortex.swift).
//
// Two modes:
//   .text  — clean-slate one-shot, no tools. For extract/synth/QA-compression.
//   .tools — agentic retrieval: read-only belt (Read/Grep/Glob/Bash) with
//            cwd = the vault; Bash exists for the `brain` ledger CLI.

import Foundation

public struct ClaudeResult: Sendable {
    public let output: String
    public let exitCode: Int32
    public let latencyMs: Int
    public let attempts: Int
    public let stderrTail: String
}

public enum ClaudeError: Error, CustomStringConvertible {
    case binaryNotFound
    case timedOut(seconds: Int)
    case failed(exitCode: Int32, stderrTail: String)
    /// Subscription session/usage limit — retrying is pointless until the
    /// window resets. Callers should COOL DOWN, not hammer.
    case limited(detail: String)

    public var description: String {
        switch self {
        case .binaryNotFound: "claude binary not found (looked in ~/.local/bin, ~/.local/share/claude, PATH)"
        case .timedOut(let s): "claude call timed out after \(s)s"
        case .failed(let rc, let err): "claude exited \(rc): \(err.prefix(400))"
        case .limited(let d): "claude usage/session limit: \(d.prefix(200))"
        }
    }
}

public enum ClaudeMode: Sendable {
    /// One-shot, no tools, no customizations. stdin prompt → stdout text.
    case text
    /// Agentic: restricted tool belt, working directory = vault.
    /// `allowedTools` uses Claude Code --allowedTools syntax, e.g.
    /// ["Read", "Grep", "Glob", "Bash(brain:*)"].
    case tools(allowed: [String], workdir: String)
}

/// Global gate: at most ONE scheduled claude subprocess at a time. The brain is
/// a single sequential loop (ralph-style) — it must never pile Opus processes
/// onto the user's subscription. Interactive asks pass `gated: false`.
actor ClaudeGate {
    static let shared = ClaudeGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()   // hand the slot to the next waiter
        }
    }
}

public struct ClaudeRunner: Sendable {
    public let config: SMConfig
    public let component: String

    public init(config: SMConfig, component: String = "claude-runner") {
        self.config = config
        self.component = component
    }

    // MARK: - Binary discovery (SSOT — port of v1 jarvis_claude_bin)

    public static func findBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/claude",
            home + "/.local/share/claude/current/bin/claude",
            home + "/.local/share/claude/current/claude",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // Last resort: PATH lookup (may be the Node shim — logged as a warning).
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let p = dir + "/claude"
            if fm.isExecutableFile(atPath: p) {
                SMLog.shared.warn("claude-runner", "non-native-binary", ["path": p])
                return p
            }
        }
        return nil
    }

    // MARK: - Run

    /// Runs claude with `prompt` (+ optional `context` appended after an
    /// INPUT CONTEXT separator). Retries once on failure with a 30s pause.
    /// `gated` (default) serializes through ClaudeGate — one scheduled claude
    /// at a time, ever. Only user-initiated asks may pass `gated: false`.
    public func run(prompt: String, context: String? = nil, mode: ClaudeMode = .text,
                    gated: Bool = true) async throws -> ClaudeResult {
        guard let bin = Self.findBinary() else {
            SMLog.shared.error(component, "binary-not-found")
            throw ClaudeError.binaryNotFound
        }
        if gated {
            let waitStart = Date()
            await ClaudeGate.shared.acquire()
            let waited = Date().timeIntervalSince(waitStart)
            if waited > 1 {
                SMLog.shared.info(component, "gate-waited", ["seconds": Int(waited)])
            }
        }
        defer { if gated { Task { await ClaudeGate.shared.release() } } }

        var fullPrompt = prompt
        if let context, !context.isEmpty {
            fullPrompt += "\n\n---\nINPUT CONTEXT:\n" + context
        }

        let modeName: String = if case .text = mode { "text" } else { "tools" }
        let start = Date()
        var lastError: ClaudeError = .failed(exitCode: -1, stderrTail: "never ran")
        for attempt in 1...2 {
            do {
                let result = try await runOnce(bin: bin, prompt: fullPrompt, mode: mode, attempt: attempt, start: start)
                SMLog.shared.info(component, "call-complete", [
                    "model": config.model, "mode": modeName, "prompt_bytes": fullPrompt.utf8.count,
                    "resp_bytes": result.output.utf8.count, "latency_ms": result.latencyMs,
                    "attempts": attempt,
                ])
                return result
            } catch let err as ClaudeError {
                lastError = err
                SMLog.shared.error(component, "call-failed", [
                    "model": config.model, "mode": modeName, "attempt": attempt, "error": String(describing: err),
                ])
                // A usage/session limit won't clear in 30s — don't burn a retry.
                if case .limited = err { throw err }
                if attempt == 1 { try? await Task.sleep(for: .seconds(30)) }
            }
        }
        throw lastError
    }

    private func runOnce(bin: String, prompt: String, mode: ClaudeMode, attempt: Int, start: Date) async throws -> ClaudeResult {
        let process = Process()

        var args = [
            "-p",
            "--model", config.model,
            "--effort", config.effort,
            "--no-session-persistence",
            "--output-format", "text",
            // Observer contract: never prompt, never customize, never touch MCP.
            "--safe-mode",
            "--permission-mode", "bypassPermissions",
            "--strict-mcp-config",
        ]
        switch mode {
        case .text:
            break
        case .tools(let allowed, let workdir):
            // Write/Edit ARE allowed now — the sandbox (layer 1) makes everything
            // but the memory dirs unwritable, so real tools are safe and reliable
            // (the WRITE-block convention was silently skippable). Still bar the
            // agentic/outbound tools that have nothing to do with observing.
            args += ["--allowedTools", allowed.joined(separator: ",")]
            args += ["--disallowedTools", "WebFetch,WebSearch,Task"]
            process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        }

        // Layer-1 read-only enforcement: run claude under a sandbox profile that
        // denies writes to the vault + sensitive paths (inherited by children).
        if let profile = Self.ensureSandboxProfile(config: config) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", profile, bin] + args
        } else {
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = args
        }

        let home = NSHomeDirectory()
        let user = NSUserName()
        // ~/.local/share/2ndm1nd/bin FIRST so the agentic tool-belt can invoke
        // `brain` (the ledger CLI). ~/.local/bin next for the native claude.
        process.environment = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": "\(home)/.local/share/2ndm1nd/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Feed the prompt and close stdin so -p mode starts.
        let promptData = Data(prompt.utf8)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: promptData)
        try? stdinPipe.fileHandleForWriting.close()

        // Read output concurrently (avoid pipe-buffer deadlock on big outputs).
        async let outData: Data = Self.readAll(stdoutPipe.fileHandleForReading)
        async let errData: Data = Self.readAll(stderrPipe.fileHandleForReading)

        // Timeout watchdog.
        let timeoutS = config.claudeTimeoutS
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeoutS))
            if process.isRunning { process.terminate() }
        }

        await Self.waitUntilExit(process)
        watchdog.cancel()

        let out = String(decoding: await outData, as: UTF8.self)
        let err = String(decoding: await errData, as: UTF8.self)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let rc = process.terminationStatus

        if process.terminationReason == .uncaughtSignal, latency >= timeoutS * 1000 {
            throw ClaudeError.timedOut(seconds: timeoutS)
        }
        // Session/usage limit shows up as a normal-looking failure (or even
        // rc==0 with the limit message as the output) — detect it explicitly.
        let combined = (out + " " + err).lowercased()
        if combined.contains("session limit") || combined.contains("usage limit")
            || combined.contains("rate limit") || combined.contains("hit your limit") {
            throw ClaudeError.limited(detail: String((err.isEmpty ? out : err).suffix(300)))
        }
        guard rc == 0 else {
            throw ClaudeError.failed(exitCode: rc, stderrTail: String(err.suffix(800)))
        }
        return ClaudeResult(
            output: out.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: rc, latencyMs: latency, attempts: attempt,
            stderrTail: String(err.suffix(400))
        )
    }

    // MARK: - Write-whitelist sandbox profile

    /// The observer's OS boundary: default-allow (claude writes its own temp/
    /// config normally), but the vault is READ-ONLY except the four memory dirs
    /// the brain owns. Last-match-wins SBPL: deny the whole vault, allow back the
    /// memory dirs, then re-deny Personal + secrets. So the model gets REAL
    /// Write/Edit tools yet physically cannot touch anything but its own memory —
    /// enforcement is the kernel, not a prompt convention (which it forgot: a
    /// session once narrated writes it never made). Returns nil only if the
    /// profile can't be written AND doesn't already exist.
    public static func ensureSandboxProfile(config: SMConfig) -> String? {
        let path = config.appData + "/claude-observer.sb"
        let home = NSHomeDirectory()
        func esc(_ p: String) -> String { p.replacingOccurrences(of: "\"", with: "") }
        var lines = ["(version 1)", "(allow default)"]
        lines.append("(deny file-write* (subpath \"\(esc(config.vault))\"))")
        // Atlas/Mind is the brain's OWN universe (self-organized ontology, skills,
        // proposals — see PROMPT.md §EVOLVE). Organizations was missing and silently
        // blocked the curate rule that routes companies there (caught 2026-07-14).
        for dir in ["Atlas/AI", "Atlas/Memory", "Atlas/Projects", "Atlas/People",
                    "Atlas/Organizations", "Atlas/Mind", "Atlas/Ideas"] {
            lines.append("(allow file-write* (subpath \"\(esc(config.vault + "/" + dir))\"))")
        }
        // Re-deny the sensitive paths AFTER the allow-backs so they win.
        var denied = config.neverRecordPaths
        denied.append(home + "/.config/gcloud")
        // The brain's own RAILS: the installed runner/binaries, the LaunchAgent
        // plists, and the runner's state files (cycle counts, fold watermark,
        // day-session ids). Self-evolution goes through Mind/proposals + human
        // review — never through the model editing its own budget enforcement.
        // (The ledger db dir stays writable: WAL readers need the -shm file.)
        denied.append(home + "/.local/share/2ndm1nd")
        denied.append(home + "/Library/LaunchAgents")
        denied.append(config.appData + "/brain-runtime")
        // SENSE-HUNTING cage (2026-07-18): the brain is mandated to EXPLORE the
        // disk read-only for new evidence sources — so secrets must be
        // OS-unreadable, not merely unwritable. Read-deny credentials outright.
        var readDenied = config.neverRecordPaths
        readDenied.append(contentsOf: [
            home + "/.ssh", home + "/.aws", home + "/.config/gcloud",
            // NOT Library/Keychains: claude's own OAuth lives there — denying it
            // broke the brain's auth for a whole night (2026-07-19, "Not logged
            // in" x6). Keychain FILES are encrypted blobs; the hard rule (never
            // probe keychains) covers the rest.
            config.appData + "/notes-quarantine",     // quarantined password notes
            // 2026-08-18: the observer now ingests text written by OTHER PEOPLE
            // (WhatsApp panes, mail bodies), so prompt injection stopped being
            // theoretical. Write containment is kernel-enforced; egress is not
            // (Bash is granted and curl is on PATH), so the defence that actually
            // holds is making the payload unreadable. These are the two files that
            // would matter: tunnel credentials, and the full-vault MCP token.
            home + "/.cloudflared",
        ])
        // Seatbelt `subpath` covers directory trees; a single file needs `literal`.
        // .env.vault-mcp sits in the vault root at mode 0644 and holds the MCP token,
        // the OAuth client secret and the OAuth password in plaintext.
        for f in [config.vault + "/.env.vault-mcp"] {
            lines.append("(deny file-read* (literal \"\(esc(f))\"))")
        }
        for p in Set(readDenied) {
            lines.append("(deny file-read* (subpath \"\(esc(p))\"))")
        }
        for p in Set(denied) {
            lines.append("(deny file-write* (subpath \"\(esc(p))\"))")
        }
        let profile = lines.joined(separator: "\n") + "\n"
        if (try? String(contentsOfFile: path, encoding: .utf8)) == profile { return path }
        do {
            try profile.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            SMLog.shared.warn("claude-runner", "sandbox-profile-write-failed", ["error": "\(error)"])
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                cont.resume(returning: data)
            }
        }
    }

    private static func waitUntilExit(_ process: Process) async {
        // waitUntilExit() blocks a thread; do it off the cooperative pool.
        // (A terminationHandler + isRunning check has a double-resume race.)
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                cont.resume()
            }
        }
    }
}
