// FocusContextSensor — the AX-first centerpiece. On app activation (and a
// 30s heartbeat while the same window stays focused), snapshot the focused
// window's accessibility context: which app, which window, and the
// app-family-specific meaning — which CHAT, which TERMINAL cwd, which
// PROJECT/file, which browser TAB. This is what makes spans human-meaning.
//
// Privacy floor first: never-record bundles emit a presence marker only.

import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class FocusContextSensor: Sensor {
    public let name = "focus-context"
    private unowned let hub: SensorHub
    private var observer: NSObjectProtocol?
    private var heartbeat: Timer?
    private var lastSnapshotKey = ""

    public init(hub: SensorHub) {
        self.hub = hub
    }

    public func start() throws {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.snapshot(app: app, trigger: "activation") }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.snapshot(app: NSWorkspace.shared.frontmostApplication, trigger: "heartbeat")
            }
        }
        // Continuity across restarts: capture whatever is frontmost now.
        snapshot(app: NSWorkspace.shared.frontmostApplication, trigger: "startup")

        if !AXIsProcessTrusted() {
            SMLog.shared.warn(name, "accessibility-denied", [
                "hint": "System Settings → Privacy & Security → Accessibility → enable 2ndm1nd",
            ])
        }
    }

    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        heartbeat?.invalidate()
    }

    // MARK: - Snapshot

    private func snapshot(app: NSRunningApplication?, trigger: String) {
        guard let app, let bundleID = app.bundleIdentifier else { return }

        if hub.isNeverRecordApp(bundleID) {
            hub.emit(SMEvent(source: "focus", kind: "privacy-blocked-presence", app: bundleID))
            return
        }

        let pid = app.processIdentifier
        let title = focusedWindowTitle(pid: pid)
        let context = FocusContext.extract(bundleID: bundleID, title: title)

        // Dedup: skip heartbeat snapshots when nothing changed.
        let key = "\(bundleID)|\(title ?? "")"
        if trigger == "heartbeat", key == lastSnapshotKey { return }
        lastSnapshotKey = key

        var payload: [String: Any] = [
            "app_name": app.localizedName ?? "",
            "trigger": trigger,
            "ax_granted": AXIsProcessTrusted(),
        ]
        if let title { payload["window_title"] = title }
        if let c = context.chat { payload["chat"] = c }
        if let c = context.terminalCwd { payload["terminal_cwd"] = c }
        if let c = context.project { payload["project"] = c }
        if let c = context.file { payload["file"] = c }
        if let c = context.browserPage { payload["browser_page"] = c }
        payload["family"] = context.family
        payload["channel"] = context.channel
        if let c = context.to { payload["to"] = c }
        if let c = context.thread { payload["thread"] = c }
        if context.addresseeUnresolved { payload["addressee_unresolved"] = true }

        let textParts = [app.localizedName, title, context.chat, context.project, context.terminalCwd]
            .compactMap { $0 }.filter { !$0.isEmpty }

        hub.emit(SMEvent(
            source: "focus", kind: "context-snapshot", app: bundleID,
            text: textParts.joined(separator: " · "),
            payload: payload
        ))
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef
        else { return nil }
        var titleRef: CFTypeRef?
        // Note: unsafeBitCast-free — window is already AXUIElement under the hood.
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }
        return titleRef as? String
    }
}

// MARK: - App-family context extraction (from window titles — cheap + robust)

public struct FocusContext: Sendable {
    public var family: String = "other"
    public var chat: String?
    public var terminalCwd: String?
    public var project: String?
    public var file: String?
    public var browserPage: String?

    // ATTRIBUTION (2026-08-05 directive: "the gathering thing should understand
    // to whom we're putting that input"). Content without an addressee is a
    // monologue — 806 WhatsApp Web exchanges were captured as exactly that, which
    // is why the brain could never resolve who "brate" is. These three fields are
    // resolved once here and stamped onto every utterance, so the addressee stops
    // living in a separate event that nothing joins.
    //   to       — WHOM this is directed at, when the channel exposes it
    //   thread   — WHAT it belongs to (conversation, project, page)
    //   channel  — normalized medium, independent of the app that hosts it
    public var to: String?
    public var thread: String?
    public var channel: String = "other"
    /// False when we know this is addressed to someone but cannot name them
    /// (browser-hosted chats today). Explicit, so the gap is measurable rather
    /// than indistinguishable from "not a conversation".
    public var addresseeUnresolved: Bool = false

    /// Chats he uses INSIDE a browser. The bundle-id family calls these windows
    /// "browser", which hides them from chat handling; matched on window title.
    /// Shared so InputSensor and the parser can never drift apart.
    public static let webChatMarkers: [(marker: String, channel: String)] = [
        ("whatsapp", "whatsapp-web"), ("telegram", "telegram-web"),
        ("messenger", "messenger-web"), ("discord", "discord-web"),
    ]

    public static func webChatChannel(for title: String?) -> String? {
        guard let t = title?.lowercased() else { return nil }
        for m in webChatMarkers where t.contains(m.marker) { return m.channel }
        return nil
    }

    public static func extract(bundleID: String, title: String?) -> FocusContext {
        var ctx = FocusContext()
        guard let title, !title.isEmpty else {
            ctx.family = family(of: bundleID)
            ctx.channel = ctx.family
            return ctx
        }
        ctx.family = family(of: bundleID)

        switch ctx.family {
        case "chat":
            // WhatsApp/Telegram/Slack/Messages put the conversation in the title.
            // Slack: "#channel - Workspace - Slack" / WhatsApp: chat name.
            var chat = title
            for suffix in [" - Slack", " – Slack", " - WhatsApp", " — WhatsApp"] {
                if chat.hasSuffix(suffix) { chat = String(chat.dropLast(suffix.count)) }
            }
            ctx.chat = chat

        case "terminal":
            // Terminal.app: "dir — cmd — 80×24"; iTerm: "session title"; both
            // commonly embed a path or ~ path.
            if let range = title.range(of: #"(~|/)[^\s—•·]*"#, options: .regularExpression) {
                ctx.terminalCwd = String(title[range])
            }
            // Project = last path component of cwd when present.
            if let cwd = ctx.terminalCwd {
                ctx.project = (cwd as NSString).lastPathComponent
            }

        case "ide":
            // VS Code/Cursor: "file — folder" or "file — folder — VS Code".
            let parts = title.components(separatedBy: " — ")
            if parts.count >= 2 {
                ctx.file = parts[0]
                ctx.project = parts[1]
            } else {
                ctx.project = title
            }

        case "browser":
            ctx.browserPage = title

        default:
            break
        }

        // Resolve the attribution from whatever the family produced.
        switch ctx.family {
        case "chat":
            ctx.channel = chatChannel(of: bundleID)
            ctx.to = ctx.chat
            ctx.thread = ctx.chat
        case "browser":
            if let webChat = Self.webChatChannel(for: title) {
                // A conversation, hosted in a browser. The tab title carries no
                // contact ("(39) WhatsApp"), and the SPA never changes its URL, so
                // the addressee has to come from the page's accessibility tree —
                // not yet wired. Record the channel and flag it UNRESOLVED rather
                // than pretending this was un-addressed typing.
                ctx.channel = webChat
                ctx.addresseeUnresolved = true
            } else {
                ctx.channel = "browser"
                ctx.thread = ctx.browserPage
            }
        case "terminal":
            // The addressee here is the machine/agent; the useful attribution is
            // WHICH work it belongs to.
            ctx.channel = "terminal"
            ctx.thread = ctx.project ?? ctx.terminalCwd
        case "ide":
            ctx.channel = "ide"
            ctx.thread = ctx.project
        default:
            ctx.channel = ctx.family
        }
        return ctx
    }

    /// Normalized channel for a native chat app, so "who I talk to where" survives
    /// the app being swapped (Slack DM vs iMessage vs WhatsApp desktop).
    static func chatChannel(of bundleID: String) -> String {
        switch bundleID {
        case "com.tinyspeck.slackmacgap":                      return "slack"
        case "com.apple.MobileSMS":                            return "messages"
        case "net.whatsapp.WhatsApp", "WhatsApp":              return "whatsapp"
        case "ru.keepcoder.Telegram", "org.telegram.desktop":  return "telegram"
        case "com.hnc.Discord":                                return "discord"
        default:                                               return "chat"
        }
    }

    static func family(of bundleID: String) -> String {
        let chat = ["net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
                    "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord",
                    "WhatsApp", "com.facebook.archon"]
        let terminal = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
        let ide = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
                   "com.jetbrains.intellij", "com.sublimetext.4", "dev.zed.Zed"]
        let browser = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                       "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac"]
        if chat.contains(bundleID) { return "chat" }
        if terminal.contains(bundleID) { return "terminal" }
        if ide.contains(bundleID) { return "ide" }
        if browser.contains(bundleID) { return "browser" }
        if bundleID == "md.obsidian" { return "notes" }
        return "other"
    }
}
