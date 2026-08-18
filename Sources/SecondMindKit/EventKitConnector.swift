// EventKitConnector — Calendar + Reminders (EventKit) as time-based ledger
// events, and Contacts (CNContactStore) seeded as Atlas/People stubs.
//
// These need their own TCC grants (Calendars, Reminders, Contacts) — separate
// from Full Disk Access. The app requests them on first run; until granted each
// no-ops with a logged warning. Async because the permission APIs are async.

import Contacts
import EventKit
import Foundation

public struct EventKitConnector: Sendable {
    public let config: SMConfig
    public let store: EventStore

    public init(config: SMConfig, store: EventStore) {
        self.config = config
        self.store = store
    }

    public func runAll() async -> [String: Int] {
        // Manual full run (`2ndm1nd eventkit`) — includes the contacts seeding,
        // which is a deliberate act (it can create many Atlas/People stubs).
        // Each sub-call is timeout-guarded so a wedged TCC request can't hang.
        var out: [String: Int] = [:]
        out["calendar"] = await Self.withTimeout(15, default: -1) { await calendar() }
        out["reminders"] = await Self.withTimeout(15, default: -1) { await reminders() }
        out["contacts"] = await Self.withTimeout(15, default: -1) { await contacts() }
        SMLog.shared.info("connector", "eventkit-ran", out.mapValues { "\($0)" })
        return out
    }

    /// Scheduled path (hourly): calendar + reminders ONLY, and only when access
    /// is ALREADY granted — the scheduler never prompts. The one-time prompts
    /// fire at app startup (`requestAccessOnce`), which the embedded
    /// __info_plist usage strings finally allow TCC to present.
    public func runScheduled() async -> [String: Int] {
        var out: [String: Int] = [:]
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            out["calendar"] = await Self.withTimeout(20, default: -1) { await calendar() }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            out["reminders"] = await Self.withTimeout(20, default: -1) { await reminders() }
        }
        if !out.isEmpty {
            SMLog.shared.info("connector", "eventkit-scheduled", out.mapValues { "\($0)" })
        }
        return out
    }

    /// One-time TCC prompts at app startup (macOS shows each prompt once; every
    /// later call returns the remembered answer instantly). Contacts is NOT
    /// requested here — its grant belongs to the deliberate manual run.
    public static func requestAccessOnce() async {
        let ek = EKEventStore()
        let cal = (try? await ek.requestFullAccessToEvents()) ?? false
        let rem = (try? await ek.requestFullAccessToReminders()) ?? false
        SMLog.shared.info("connector", "eventkit-access", ["calendar": "\(cal)", "reminders": "\(rem)"])
    }

    /// Append-only ledger + a rescanning ±30d window ⇒ dedup belongs here.
    /// Calendar rows are identical on (source, ts, text) across runs; reminders
    /// without a due date fall back to "now" for ts, so they dedup on text alone.
    private func exists(source: String, ts: Double?, text: String) -> Bool {
        let esc = text.replacingOccurrences(of: "'", with: "''")
        var sql = "SELECT 1 FROM events WHERE source='\(source)' AND text='\(esc)'"
        if let ts { sql += " AND ts=\(ts)" }
        sql += " LIMIT 1"
        return ((try? store.rawQuery(sql, limit: 1))?.isEmpty == false)
    }

    /// Race an async op against a deadline; returns `default` if it doesn't finish.
    static func withTimeout(_ seconds: Double, default def: Int, _ op: @escaping @Sendable () async -> Int) async -> Int {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next()
            group.cancelAll()
            if let inner = first, let value = inner { return value }
            SMLog.shared.warn("connector", "eventkit-timeout", ["hint": "needs .app bundle w/ usage strings + TCC grant"])
            return def
        }
    }

    // MARK: - Calendar (±30 days window)

    private func calendar() async -> Int {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else {
            SMLog.shared.warn("connector", "calendar-denied", ["hint": "System Settings → Privacy & Security → Calendars → enable 2ndm1nd"])
            return 0
        }
        let now = Date()
        let start = now.addingTimeInterval(-30 * 86400)
        let end = now.addingTimeInterval(30 * 86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        var count = 0
        for ev in events {
            guard let s = ev.startDate else { continue }
            let title = ev.title ?? "(untitled)"
            guard !exists(source: "calendar", ts: s.timeIntervalSince1970, text: title) else { continue }
            let e = SMEvent(
                ts: s.timeIntervalSince1970, source: "calendar", kind: "event", app: nil,
                text: title,
                payload: [
                    "title": title, "start": s.timeIntervalSince1970,
                    "end": (ev.endDate ?? s).timeIntervalSince1970,
                    "all_day": ev.isAllDay, "calendar": ev.calendar?.title ?? "",
                    "attendees": ev.attendees?.count ?? 0,
                ])
            do { try self.store.insert([e]); count += 1 } catch {}
        }
        return count
    }

    // MARK: - Reminders (incomplete)

    private func reminders() async -> Int {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else {
            SMLog.shared.warn("connector", "reminders-denied", ["hint": "System Settings → Privacy & Security → Reminders → enable 2ndm1nd"])
            return 0
        }
        struct RD: Sendable { let title: String; let ts: Double; let list: String; let priority: Int }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Extract Sendable data INSIDE the completion handler (EKReminder is not Sendable).
        let items: [RD] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).compactMap { r -> RD? in
                    guard let t = r.title, !t.isEmpty else { return nil }
                    return RD(title: t, ts: r.dueDateComponents?.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                              list: r.calendar?.title ?? "", priority: r.priority)
                }
                cont.resume(returning: mapped)
            }
        }
        var count = 0
        for r in items {
            let title = r.title
            guard !exists(source: "reminders", ts: nil, text: title) else { continue }
            let e = SMEvent(ts: r.ts, source: "reminders", kind: "todo", app: nil, text: title,
                            payload: ["title": title, "list": r.list, "priority": r.priority])
            do { try self.store.insert([e]); count += 1 } catch {}
        }
        return count
    }

    // MARK: - Contacts → Atlas/People stubs (memory seeding, Phase 4.1)

    private func contacts() async -> Int {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else {
            SMLog.shared.warn("connector", "contacts-denied", ["hint": "System Settings → Privacy & Security → Contacts → enable 2ndm1nd"])
            return 0
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        let peopleDir = config.vault + "/Atlas/People"
        try? FileManager.default.createDirectory(atPath: peopleDir, withIntermediateDirectories: true)
        var seeded = 0
        try? store.enumerateContacts(with: req) { c, _ in
            let name = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let safe = name.replacingOccurrences(of: "/", with: "-")
            let path = peopleDir + "/\(safe).md"
            // Seed ONLY if the file doesn't exist — never overwrite the extractor's richer facts.
            guard !FileManager.default.fileExists(atPath: path) else { return }
            var fm = "---\ntype: person\n"
            if !c.nickname.isEmpty { fm += "aliases: [\(c.nickname)]\n" }
            fm += "source: contacts\nupdated: \(Cortex.today())\n---\n\n# \(name)\n\n"
            if !c.organizationName.isEmpty { fm += "- \(Cortex.today()) :: works at \(c.organizationName) (from Contacts)\n" }
            try? fm.write(toFile: path, atomically: true, encoding: .utf8)
            seeded += 1
        }
        return seeded
    }

}
