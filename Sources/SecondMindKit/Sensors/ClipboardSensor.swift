// ClipboardSensor — polls NSPasteboard.changeCount. Captures the copied text
// verbatim for every app EXCEPT never_record apps (password managers/banking),
// which emit a presence marker only — no content, no length, no hash.

import AppKit
import CryptoKit
import Foundation

@MainActor
public final class ClipboardSensor: Sensor {
    public let name = "clipboard"
    private unowned let hub: SensorHub
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    public init(hub: SensorHub) {
        self.hub = hub
    }

    public func start() throws {
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    public func stop() { timer?.invalidate() }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Password-manager/banking copy: presence marker ONLY — even a length or
        // hash of a copied password is a fingerprint.
        if hub.isNeverRecordApp(front) {
            hub.emit(SMEvent(source: "clipboard", kind: "privacy-blocked-presence", app: front))
            return
        }
        guard let text = pb.string(forType: .string) else {
            hub.emit(SMEvent(source: "clipboard", kind: "clipboard-nontext", app: front))
            return
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        hub.emit(SMEvent(
            source: "clipboard", kind: "clipboard-changed", app: front,
            text: String(text.prefix(10000)),
            payload: ["length": text.count, "sha256": digest, "app": front ?? "", "captured": true]
        ))
    }
}
