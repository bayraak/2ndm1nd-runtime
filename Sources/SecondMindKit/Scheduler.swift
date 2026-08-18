// Scheduler — the in-app replacement for v1's 27 launchd plists. One actor
// runs every periodic job on a wall-clock cadence: sessionize (hourly),
// retention (nightly), and the cortex tiers (Phase 5). Fire-on-schedule with
// a cheap 60s tick so a laptop that was asleep catches up on wake.

import Foundation

public struct ScheduledJob: Sendable {
    public let name: String
    /// Returns true if the job should run now given the current local time and
    /// when it last ran (nil = never).
    public let due: @Sendable (_ now: Date, _ lastRun: Date?) -> Bool
    public let run: @Sendable () async -> Void

    public init(name: String,
                due: @escaping @Sendable (Date, Date?) -> Bool,
                run: @escaping @Sendable () async -> Void) {
        self.name = name
        self.due = due
        self.run = run
    }
}

public actor Scheduler {
    private var jobs: [ScheduledJob] = []
    private var lastRun: [String: Date] = [:]
    private var running: Set<String> = []
    private var ticker: Task<Void, Never>?
    private let statePath: String

    public init(stateDir: String) {
        statePath = stateDir + "/scheduler-state.json"
        lastRun = Self.loadState(from: statePath)
    }

    public func add(_ job: ScheduledJob) {
        jobs.append(job)
    }

    public func start() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        SMLog.shared.info("scheduler", "started", ["jobs": jobs.map(\.name).joined(separator: ",")])
    }

    public func stop() { ticker?.cancel() }

    /// Run one job immediately by name (for CLI/testing).
    public func runNow(_ name: String) async {
        guard let job = jobs.first(where: { $0.name == name }) else { return }
        await execute(job)
    }

    /// Each due job runs in its OWN task — a 30-min hung cortex call must never
    /// stall sessionize/connectors/solver (they used to run sequentially).
    /// `running` guards against the same job overlapping itself.
    private func tick() async {
        let now = Date()
        for job in jobs where !running.contains(job.name) && job.due(now, lastRun[job.name]) {
            running.insert(job.name)
            Task { [weak self] in await self?.execute(job) }
        }
    }

    private func execute(_ job: ScheduledJob) async {
        let start = Date()
        SMLog.shared.info("scheduler", "job-start", ["job": job.name])
        await job.run()
        lastRun[job.name] = Date()
        running.remove(job.name)
        saveState()
        SMLog.shared.info("scheduler", "job-done", [
            "job": job.name, "seconds": Int(Date().timeIntervalSince(start)),
        ])
    }

    // MARK: - State persistence (survive restarts / reboots)

    private static func loadState(from path: String) -> [String: Date] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return [:] }
        return obj.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveState() {
        let obj = lastRun.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }
    }
}

// MARK: - Due-predicate helpers

public enum Due {
    /// Fire once per calendar hour (at most).
    public static func hourly(now: Date, lastRun: Date?) -> Bool {
        guard let last = lastRun else { return true }
        return !Calendar.current.isDate(now, equalTo: last, toGranularity: .hour)
    }

    /// Fire every N minutes (interval-based, not clock-aligned).
    public static func every(minutes: Int) -> @Sendable (Date, Date?) -> Bool {
        { now, lastRun in
            guard let last = lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(minutes) * 60 - 30
        }
    }

    /// Fire at/after HH:mm local, once per day.
    public static func dailyAt(_ hour: Int, _ minute: Int) -> @Sendable (Date, Date?) -> Bool {
        { now, lastRun in
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute], from: now)
            guard (comps.hour ?? 0) > hour || ((comps.hour == hour) && (comps.minute ?? 0) >= minute) else { return false }
            guard let last = lastRun else { return true }
            return !cal.isDate(now, inSameDayAs: last)
        }
    }

    /// Fire at/after HH:mm on a given weekday (1=Sun…7=Sat), once per week.
    /// Catchup: if the Mac slept through the whole weekday, fire on the next
    /// tick once >8 days have passed since the last run — never skip a week.
    public static func weeklyAt(weekday: Int, _ hour: Int, _ minute: Int) -> @Sendable (Date, Date?) -> Bool {
        { now, lastRun in
            let cal = Calendar.current
            let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
            if comps.weekday == weekday {
                guard (comps.hour ?? 0) > hour || ((comps.hour == hour) && (comps.minute ?? 0) >= minute) else { return false }
                guard let last = lastRun else { return true }
                return now.timeIntervalSince(last) > 6 * 86400
            }
            // Missed the weekday entirely (asleep/off) → run late rather than never.
            if let last = lastRun { return now.timeIntervalSince(last) > 8 * 86400 }
            return false
        }
    }
}
