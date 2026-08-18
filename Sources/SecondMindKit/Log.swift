// SMLog — JSONL logger matching the v1 envelope convention:
//   {"ts":"<iso8601-tz>","component":"<kebab>","level":"info|warn|error|debug",
//    "event":"<kebab>","payload":{...}}
// File: <logsDir>/secondmind.jsonl (one file for the whole app; `component`
// distinguishes subsystems). Also mirrors to OSLog for Console.app.

import Foundation
import os

public final class SMLog: @unchecked Sendable {
    public static let shared = SMLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var path: String = ""
    private var writesSinceCheck = 0
    private static let rotateOverBytes: UInt64 = 20 * 1024 * 1024   // 20 MB → .1
    private let oslog = Logger(subsystem: "org.2ndm1nd.app", category: "app")

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public func configure(logsDir: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        path = logsDir + "/2ndm1nd.jsonl"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        try? handle?.seekToEnd()
    }

    public func info(_ component: String, _ event: String, _ payload: [String: Any] = [:]) {
        emit("info", component, event, payload)
    }
    public func warn(_ component: String, _ event: String, _ payload: [String: Any] = [:]) {
        emit("warn", component, event, payload)
    }
    public func error(_ component: String, _ event: String, _ payload: [String: Any] = [:]) {
        emit("error", component, event, payload)
    }

    private func emit(_ level: String, _ component: String, _ event: String, _ payload: [String: Any]) {
        let ts = Self.isoFormatter.string(from: Date())
        var line: [String: Any] = [
            "ts": ts, "component": component, "level": level, "event": event,
        ]
        line["payload"] = payload.isEmpty ? [:] : payload
        guard JSONSerialization.isValidJSONObject(line),
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else {
            oslog.error("log-serialize-failed: \(component)/\(event)")
            return
        }
        lock.lock(); defer { lock.unlock() }
        if let handle {
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
            rotateIfNeeded()
        }
        let msg = "\(component)/\(event)"
        switch level {
        case "error": oslog.error("\(msg, privacy: .public)")
        case "warn": oslog.warning("\(msg, privacy: .public)")
        default: oslog.info("\(msg, privacy: .public)")
        }
    }

    /// Size-capped rotation (single .1 generation) — an always-on daemon must
    /// not grow its JSONL unbounded. Called under `lock`, checked cheaply.
    private func rotateIfNeeded() {
        writesSinceCheck += 1
        guard writesSinceCheck >= 2000 else { return }
        writesSinceCheck = 0
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64,
              size > Self.rotateOverBytes else { return }
        try? handle?.close()
        try? fm.removeItem(atPath: path + ".1")
        try? fm.moveItem(atPath: path, toPath: path + ".1")
        fm.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        oslog.info("log-rotated")
    }
}
