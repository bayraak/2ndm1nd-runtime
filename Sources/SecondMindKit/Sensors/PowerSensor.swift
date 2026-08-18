// PowerSensor — sleep / wake / screensaver / screen-lock, event-driven via
// NSWorkspace + DistributedNotificationCenter (zero polling). Emits a startup
// snapshot for timeline continuity.

import AppKit
import Foundation

@MainActor
public final class PowerSensor: Sensor {
    public let name = "power"
    private unowned let hub: SensorHub
    private var tokens: [NSObjectProtocol] = []

    public init(hub: SensorHub) {
        self.hub = hub
    }

    public func start() throws {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let wsEvents: [(NSNotification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "will-sleep"),
            (NSWorkspace.didWakeNotification, "did-wake"),
            (NSWorkspace.screensDidSleepNotification, "screens-sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens-wake"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session-active"),
            (NSWorkspace.sessionDidResignActiveNotification, "session-resign"),
        ]
        for (name, kind) in wsEvents {
            tokens.append(wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.emit(kind) }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        let dncEvents = [
            ("com.apple.screensaver.didstart", "screensaver-start"),
            ("com.apple.screensaver.didstop", "screensaver-stop"),
            ("com.apple.screenIsLocked", "screen-locked"),
            ("com.apple.screenIsUnlocked", "screen-unlocked"),
        ]
        for (name, kind) in dncEvents {
            tokens.append(dnc.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.emit(kind) }
            })
        }
        emit("startup-snapshot")
    }

    public func stop() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
    }

    private func emit(_ kind: String) {
        hub.emit(SMEvent(source: "power", kind: kind))
    }
}
