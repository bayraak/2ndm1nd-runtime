// 2ndm1nd — second brain app entry point.
//
//   2ndm1nd                    → menu-bar app (the always-on brain)
//   2ndm1nd --version
//   2ndm1nd claude-smoke       → live ClaudeRunner text smoke (HEADLESS_OK)
//   2ndm1nd claude-tools-smoke → live tool-belt smoke (greps the vault)
//   2ndm1nd sessionize [day]   → rebuild activity spans for a day
//   2ndm1nd prune [days]       → retention: delete events older than N days
//   2ndm1nd cortex <tier>      → run one cortex tier now (solver/daily/…)
//   2ndm1nd brain-session      → run the once-daily self-learning brain now
//   2ndm1nd serve              → run BrainServer in the foreground (debug)

import AppKit
import Foundation
import SecondMindKit

let SM_VERSION = "0.1.0"
let args = Array(CommandLine.arguments.dropFirst())

// MARK: - Subcommand plumbing

final class ExitBox: @unchecked Sendable {
    private var code: Int32 = 0
    private let lock = NSLock()
    func set(_ c: Int32) { lock.lock(); code = c; lock.unlock() }
    func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return code }
}

func runAndExit(_ body: @escaping @Sendable () async -> Int32) -> Never {
    let sem = DispatchSemaphore(value: 0)
    let box = ExitBox()
    Task.detached { box.set(await body()); sem.signal() }
    sem.wait()
    exit(box.get())
}

func bootstrapConfig() -> SMConfig {
    let c = SMConfig.load()
    c.ensureDirectories()
    SMLog.shared.configure(logsDir: c.logsDir)
    return c
}

switch args.first {
case "--version", "version":
    print("2ndm1nd \(SM_VERSION)"); exit(0)

case "claude-smoke":
    let config = bootstrapConfig()
    runAndExit {
        do {
            let r = try await ClaudeRunner(config: config, component: "claude-smoke")
                .run(prompt: "Reply with exactly: HEADLESS_OK — nothing else.", mode: .text)
            print(r.output)
            return r.output.contains("HEADLESS_OK") ? 0 : 1
        } catch { FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8)); return 1 }
    }

case "claude-tools-smoke":
    let config = bootstrapConfig()
    runAndExit {
        do {
            let r = try await ClaudeRunner(config: config, component: "claude-tools-smoke").run(
                prompt: "Use Grep to count lines in CLAUDE.md containing \"vault\" (case-insensitive). Reply exactly: TOOLS_OK <count>.",
                mode: .tools(allowed: ["Read", "Grep", "Glob"], workdir: config.vault))
            print(r.output)
            return r.output.contains("TOOLS_OK") ? 0 : 1
        } catch { FileHandle.standardError.write(Data("tools smoke failed: \(error)\n".utf8)); return 1 }
    }

case "sessionize":
    let config = bootstrapConfig()
    let day = args.count > 1 ? args[1] : Cortex.today()
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL)
            let spans = try Sessionizer(config: config, store: store).rebuild(day: day)
            print("sessionized \(day): \(spans.count) spans → Atlas/AI/spans/\(day).md")
            return 0
        } catch { FileHandle.standardError.write(Data("sessionize failed: \(error)\n".utf8)); return 1 }
    }

case "prune":
    let config = bootstrapConfig()
    let days = args.count > 1 ? (Int(args[1]) ?? 365) : 365
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL)
            let deleted = try store.pruneEvents(olderThanDays: days)
            print("pruned \(deleted) events older than \(days) days")
            return 0
        } catch { FileHandle.standardError.write(Data("prune failed: \(error)\n".utf8)); return 1 }
    }

case "cortex":
    let config = bootstrapConfig()
    guard args.count > 1, let tier = Cortex.Tier(rawValue: args[1]) else {
        FileHandle.standardError.write(Data("usage: 2ndm1nd cortex <\(Cortex.Tier.allCases.map(\.rawValue).joined(separator: "|"))>\n".utf8))
        exit(2)
    }
    let day: String? = args.count > 2 ? args[2] : nil
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            let ok = await Cortex(config: config, store: store).run(tier, day: day) == .success
            print(ok ? "cortex \(tier.rawValue): done" : "cortex \(tier.rawValue): FAILED (see log)")
            return ok ? 0 : 1
        } catch { FileHandle.standardError.write(Data("cortex failed: \(error)\n".utf8)); return 1 }
    }

case "brain-session", "brain":
    // The once-daily brain session (launchd org.2ndm1nd.brain fires this).
    // Reads the day's queue, folds it, learns, rewrites its handoff letter.
    let config = bootstrapConfig()
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            await Cortex(config: config, store: store).runBrainSession(daily: true)
            print("brain session: done (see \(config.logsDir)/2ndm1nd.jsonl)")
            return 0
        } catch { FileHandle.standardError.write(Data("brain session failed: \(error)\n".utf8)); return 1 }
    }

case "sandbox-profile":
    // Write the write-whitelist sandbox profile (SSOT) and print its path, so
    // the shell shift-runner can wrap `claude` with the same OS boundary.
    let config = bootstrapConfig()
    if let p = ClaudeRunner.ensureSandboxProfile(config: config) { print(p); exit(0) }
    FileHandle.standardError.write(Data("sandbox-profile: failed to write\n".utf8)); exit(1)

case "brain-scaffold":
    // Seed the brain's memory files (PROMPT.md, SELF.md, HANDOFF.md, …) if
    // missing. The shift runner calls this before launching a session.
    let config = bootstrapConfig()
    runAndExit {
        let store = (try? EventStore(url: config.ledgerURL, readOnly: true))
            ?? (try! EventStore(url: config.ledgerURL))
        Cortex(config: config, store: store).ensureBrainScaffold()
        print("brain scaffold ready: \(config.vault)/Atlas/AI/Brain")
        return 0
    }

case "brain-weekly":
    // The Sunday higher-order reflection (launchd org.2ndm1nd.brain.weekly).
    let config = bootstrapConfig()
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL, readOnly: true)
            await Cortex(config: config, store: store).runWeeklyReflection()
            print("weekly reflection: done (see \(config.logsDir)/2ndm1nd.jsonl)")
            return 0
        } catch { FileHandle.standardError.write(Data("weekly reflection failed: \(error)\n".utf8)); return 1 }
    }

case "connect":
    let config = bootstrapConfig()
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL)
            let c = Connectors(config: config, store: store)
            if args.count > 1, let name = Connectors.Name(rawValue: args[1]) {
                let n = c.run(name)
                print("connector \(name.rawValue): \(n) events")
            } else {
                let all = c.runAll()
                for (k, v) in all.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v) events") }
            }
            return 0
        } catch { FileHandle.standardError.write(Data("connect failed: \(error)\n".utf8)); return 1 }
    }

case "eventkit":
    let config = bootstrapConfig()
    runAndExit {
        do {
            let store = try EventStore(url: config.ledgerURL)
            let out = await EventKitConnector(config: config, store: store).runAll()
            for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
            return 0
        } catch { FileHandle.standardError.write(Data("eventkit failed: \(error)\n".utf8)); return 1 }
    }

case "serve":
    let config = bootstrapConfig()
    do {
        let server = BrainServer(config: config)
        try server.start()
        print("BrainServer on http://127.0.0.1:\(config.serverPort)  token: \(server.authToken)")
        RunLoop.main.run()
    } catch { FileHandle.standardError.write(Data("serve failed: \(error)\n".utf8)); exit(1) }
    exit(0)

case .some(let unknown):
    FileHandle.standardError.write(Data("unknown subcommand: \(unknown)\n".utf8)); exit(2)

case .none:
    break // fall through to the menu-bar app
}

// MARK: - Menu-bar app (the always-on brain)

let config = bootstrapConfig()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let config: SMConfig
    var store: EventStore!
    var hub: SensorHub!
    var scheduler: Scheduler!
    var server: BrainServer!
    var permTimer: Timer?

    init(config: SMConfig) { self.config = config; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧠"

        do {
            store = try EventStore(url: config.ledgerURL)
        } catch {
            // Degraded mode, NOT a crash loop: a locked/corrupt ledger used to
            // hit a force-unwrap below → crash → KeepAlive restart every 30s.
            SMLog.shared.error("app", "ledger-open-failed", ["error": "\(error)"])
            statusItem.button?.title = "🧠⚠️"
            let menu = NSMenu()
            let item = NSMenuItem(title: "Ledger failed to open — see log", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Quit 2ndm1nd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
            return
        }

        // Sensors
        hub = SensorHub(config: config, store: store)
        hub.start()

        // BrainServer
        server = BrainServer(config: config)
        try? server.start()

        // Scheduler: sessionize hourly, retention nightly, cortex tiers on cadence.
        // Add ALL jobs, THEN start (single task — avoids the add/start race).
        scheduler = Scheduler(stateDir: config.appData)
        wireJobs()

        let menu = NSMenu()
        menu.delegate = self          // menuNeedsUpdate rebuilds it live on every open
        statusItem.menu = menu
        refreshBadge()
        permTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBadge() }
        }
        SMLog.shared.info("app", "started", [
            "version": SM_VERSION, "vault": config.vault, "server_port": config.serverPort,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ])

        // EventKit one-time TCC prompts. The usage strings live in the binary's
        // embedded __info_plist section (Package.swift linkerSettings) — without
        // them TCC refuses to present and the request would hang. macOS shows
        // each prompt once; afterwards this call is an instant no-op.
        Task { await EventKitConnector.requestAccessOnce() }
    }

    func wireJobs() {
        let config = self.config
        let sessionizer = Sessionizer(config: config, store: store)
        let cortexStore = store!

        Task {
            await scheduler.add(ScheduledJob(name: "sessionize", due: { n, l in Due.hourly(now: n, lastRun: l) }, run: {
                try? sessionizer.rebuild(day: Cortex.today())
            }))
            // ONE shared pool for every job — the old per-job EventStore opens
            // meant three concurrent write pools on the same SQLite file.
            await scheduler.add(ScheduledJob(name: "retention", due: Due.dailyAt(3, 0), run: {
                do { _ = try cortexStore.pruneEvents(olderThanDays: 365) }
                catch { SMLog.shared.error("scheduler", "retention-failed", ["error": "\(error)"]) }
            }))
            await scheduler.add(ScheduledJob(name: "connectors", due: { n, l in Due.hourly(now: n, lastRun: l) }, run: {
                _ = Connectors(config: config, store: cortexStore).runAll()
            }))
            // EventKit scheduled path: calendar + reminders hourly, deduped,
            // and ONLY when access is already granted — it never prompts (the
            // one-time prompts fire at app startup, which the embedded
            // __info_plist usage strings finally let TCC present). Contacts
            // seeding stays manual (`2ndm1nd eventkit`) — it can create many
            // Atlas/People stubs and should be a deliberate act.
            await scheduler.add(ScheduledJob(name: "eventkit", due: { n, l in Due.hourly(now: n, lastRun: l) }, run: {
                _ = await EventKitConnector(config: config, store: cortexStore).runScheduled()
            }))
            // NOTE: the app runs NO claude calls (user directive 2026-07-12:
            // "one daily session"). The brain is a SEPARATE launchd job
            // (org.2ndm1nd.brain, macOS's cron) that fires once a day and runs
            // `2ndm1nd brain-session`. This app owns only capture + the
            // deterministic housekeeping jobs above (sessionize/retention/
            // connectors — no LLM). solver/daily/weekly/curator: on demand via
            // `2ndm1nd cortex <tier>`.
            _ = cortexStore   // retained for the brain-session subcommand path
            await scheduler.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard hub != nil else { return }
        // Graceful teardown: stop intake, then drain the buffered writer so the
        // last ≤200 events aren't lost on quit/restart.
        hub.setPaused(true)
        server?.stop()
        let writer = hub.writer
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await writer.flushNow()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        SMLog.shared.info("app", "terminated-cleanly")
    }

    func refreshBadge() {
        let status = Permissions.check()
        statusItem.button?.title = hub.paused ? "🧠⏸" : (status.allGranted ? "🧠" : "🧠⚠️")
    }

    // Called by NSMenuDelegate right before the menu is shown → always current.
    func menuNeedsUpdate(_ menu: NSMenu) { populateMenu(menu) }

    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = Permissions.check()
        let header = NSMenuItem(title: "2ndm1nd v\(SM_VERSION)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Live permission lines — each opens ITS OWN Settings pane (via representedObject).
        for (label, state, key) in [
            ("Accessibility", status.accessibility, "accessibility"),
            ("Input Monitoring", status.inputMonitoring, "input_monitoring"),
            ("Full Disk Access", status.fullDiskAccess, "full_disk_access"),
        ] {
            let icon = state == .granted ? "✓" : (state == .denied ? "✗" : "?")
            let item = NSMenuItem(title: "\(icon) \(label)", action: #selector(openPermissions(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: hub.paused ? "Resume Capture" : "Pause Capture", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)

        let ask = NSMenuItem(title: "Open Trigger.md (ask)", action: #selector(openTrigger), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit 2ndm1nd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func togglePause() {
        hub.setPaused(!hub.paused)
        refreshBadge()   // menu itself refreshes on next open via menuNeedsUpdate
    }

    @objc func openPermissions(_ sender: Any?) {
        Permissions.request()
        let key = (sender as? NSMenuItem)?.representedObject as? String ?? "accessibility"
        if let str = Permissions.settingsURLs[key], let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openTrigger() {
        let path = config.vault + "/Atlas/AI/Trigger.md"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
