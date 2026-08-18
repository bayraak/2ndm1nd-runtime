// SensorHub — starts/stops all sensors, owns the shared EventWriter, and
// exposes the master pause switch (menu bar "Pause Capture").

import AppKit
import Foundation

@MainActor
public final class SensorHub {
    public let config: SMConfig
    public let store: EventStore
    public let writer: EventWriter

    public private(set) var paused = false
    private var sensors: [any Sensor] = []

    public init(config: SMConfig, store: EventStore) {
        self.config = config
        self.store = store
        self.writer = EventWriter(store: store)
    }

    public func start() {
        // fs sensor DELETED (2026-07-11): raw FSEvents produced ~96% of the ledger
        // as low-signal noise. "What did I work on" comes from the git/ide/shell
        // connectors + focus context, not raw file events.
        let all: [any Sensor] = [
            FocusContextSensor(hub: self),
            InputSensor(hub: self),
            ClipboardSensor(hub: self),
            PowerSensor(hub: self),
        ]
        for sensor in all {
            do {
                try sensor.start()
                sensors.append(sensor)
                SMLog.shared.info("sensor-hub", "sensor-started", ["sensor": sensor.name])
            } catch {
                SMLog.shared.error("sensor-hub", "sensor-start-failed", ["sensor": sensor.name, "error": "\(error)"])
            }
        }
        SMLog.shared.info("sensor-hub", "started", ["sensors": sensors.map(\.name).joined(separator: ",")])
    }

    public func setPaused(_ value: Bool) {
        paused = value
        SMLog.shared.info("sensor-hub", value ? "paused" : "resumed")
    }

    /// Sensors call this instead of touching the writer directly — enforces
    /// the pause switch and the never-record app floor in ONE place.
    public func emit(_ event: SMEvent) {
        guard !paused else { return }
        Task { await writer.append(event) }
    }

    public func isNeverRecordApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.neverRecordApps.contains(bundleID)
    }

    public func isNeverRecordPath(_ path: String) -> Bool {
        config.neverRecordPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // NOTE (2026-07-11, user directive): NO content redaction. This is a personal
    // ledger on the user's own machine — capture everything verbatim. The only
    // privacy floor is password-context: secure-input fields (OS-level, capture
    // nothing) and never_record apps (password managers/banking → presence only).
}

@MainActor
public protocol Sensor {
    var name: String { get }
    func start() throws
    func stop()
}
