import Foundation
import Testing
@testable import SecondMindKit

// The Due predicates are pure (Date, Date?) -> Bool, so they get fixed,
// calendar-constructed dates — no Date.now anywhere. The Scheduler actor is
// exercised through runNow (no ticker) plus one start() round-trip that
// proves persisted state survives a restart; launchd is never involved.

private func makeTmpDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("smtest-sched-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Build a local date from components with the same calendar the predicates
/// use, so hour/day/week granularity comparisons agree with the test's intent.
/// Mid-January dates keep well clear of DST transitions in any zone.
private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite struct DuePredicateTests {

    @Test func hourlyFiresOncePerCalendarHour() {
        let now = date(2026, 1, 14, 10, 45)
        #expect(Due.hourly(now: now, lastRun: nil) == true)                       // never ran
        #expect(Due.hourly(now: now, lastRun: date(2026, 1, 14, 10, 5)) == false) // same hour
        #expect(Due.hourly(now: now, lastRun: date(2026, 1, 14, 9, 59)) == true)  // previous hour
        #expect(Due.hourly(now: now, lastRun: date(2026, 1, 13, 10, 45)) == true) // same hour, other day
    }

    @Test func everyMinutesIsIntervalBasedWithSlack() {
        let due = Due.every(minutes: 30)
        let now = date(2026, 1, 14, 12, 0)
        #expect(due(now, nil) == true)
        #expect(due(now, now.addingTimeInterval(-31 * 60)) == true)
        // 30s of slack: 29m30s since last already counts as due…
        #expect(due(now, now.addingTimeInterval(-(30 * 60 - 30))) == true)
        // …but a fresh run is not.
        #expect(due(now, now.addingTimeInterval(-10 * 60)) == false)
    }

    @Test func dailyAtFiresAfterTheClockTimeOncePerDay() {
        let due = Due.dailyAt(7, 30)
        #expect(due(date(2026, 1, 14, 6, 59), nil) == false)   // too early, even if never ran
        #expect(due(date(2026, 1, 14, 7, 29), nil) == false)
        #expect(due(date(2026, 1, 14, 7, 30), nil) == true)    // exact minute counts
        #expect(due(date(2026, 1, 14, 23, 0), nil) == true)
        // Already ran today → not due again.
        #expect(due(date(2026, 1, 14, 8, 0), date(2026, 1, 14, 7, 31)) == false)
        // Last ran yesterday → due.
        #expect(due(date(2026, 1, 14, 8, 0), date(2026, 1, 13, 7, 31)) == true)
    }

    @Test func weeklyAtFiresOnTheWeekdayOncePerWeek() {
        let now = date(2026, 1, 14, 9, 0)
        let weekday = Calendar.current.component(.weekday, from: now)
        let due = Due.weeklyAt(weekday: weekday, 8, 0)

        #expect(due(now, nil) == true)                                     // right day, past time, never ran
        #expect(due(date(2026, 1, 14, 7, 59), nil) == false)               // right day, too early
        #expect(due(now, now.addingTimeInterval(-2 * 86400)) == false)     // ran 2 days ago
        #expect(due(now, now.addingTimeInterval(-7 * 86400)) == true)      // a week ago → due again
    }

    @Test func weeklyAtCatchesUpAfterAMissedWeekday() {
        let now = date(2026, 1, 14, 9, 0)
        let weekday = Calendar.current.component(.weekday, from: now)
        let otherWeekday = weekday % 7 + 1   // guaranteed ≠ today's weekday
        let due = Due.weeklyAt(weekday: otherWeekday, 8, 0)

        #expect(due(now, nil) == false)                                    // wrong day, never ran: wait
        #expect(due(now, now.addingTimeInterval(-3 * 86400)) == false)     // wrong day, ran recently
        #expect(due(now, now.addingTimeInterval(-9 * 86400)) == true)      // slept through it → run late
    }
}

@Suite struct SchedulerTests {

    @Test func runNowExecutesTheNamedJobAndPersistsState() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let counter = Counter()
        let sched = Scheduler(stateDir: dir)
        await sched.add(ScheduledJob(name: "job1", due: { _, _ in false },
                                     run: { await counter.increment() }))

        await sched.runNow("job1")
        #expect(await counter.value == 1)

        await sched.runNow("no-such-job")   // unknown name: silent no-op
        #expect(await counter.value == 1)

        // execute() must have written scheduler-state.json with the job's name.
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/scheduler-state.json"))
        let state = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Double])
        #expect(state["job1"] != nil)
    }

    @Test func persistedStateSurvivesARestart() async throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // First life: run "once" so its lastRun lands in the state file.
        let first = Scheduler(stateDir: dir)
        await first.add(ScheduledJob(name: "once", due: { _, _ in false }, run: {}))
        await first.runNow("once")

        // Second life: two jobs share the SAME due predicate (run only if
        // never ran). "probe" has no history → fires on the first tick;
        // "once" has persisted history → must stay silent. The differential
        // outcome can only come from loaded state.
        let onceCounter = Counter()
        let probeCounter = Counter()
        let second = Scheduler(stateDir: dir)
        await second.add(ScheduledJob(name: "once", due: { _, last in last == nil },
                                      run: { await onceCounter.increment() }))
        await second.add(ScheduledJob(name: "probe", due: { _, last in last == nil },
                                      run: { await probeCounter.increment() }))
        await second.start()

        for _ in 0..<500 {   // wait (max ~5s) for the first tick to reach "probe"
            if await probeCounter.value >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probeCounter.value >= 1)

        // Both due-checks happened in the same tick; give the spawned task a
        // moment, then confirm the restored state kept "once" from running.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await onceCounter.value == 0)
        await second.stop()
    }
}
