// InputSensor — CGEventTap keystroke/mouse capture. Reconstructs the ACTUAL
// text you type (the point of a second brain: "what am I writing, to what") and
// stores it in the FTS-indexed `text` field, tagged with the focused app.
//
// Q/A capture: when you type a reply in a terminal or chat, it snapshots the
// on-screen context at answer-start (via Accessibility) and stores a
// "Q: <context> / A: <your literal reply>" pair — RAW, no LLM. Capture never
// calls claude (2026-07-11 directive: the periodic brain tick does all LLM
// work in batch; event-driven Opus calls were burning the subscription).
//
// Privacy floor (password-contexts only — user directive 2026-07-11: no other
// redaction, this is a personal ledger, capture verbatim):
//   • secure-input fields (password boxes) → OS blocks the tap; captured as nothing
//   • never_record apps (1Password/Bitwarden/banking) → not emitted at all
//
// v1 lesson baked in: preflight Input Monitoring and surface denial loudly —
// the tap "succeeds" without the grant but delivers nothing.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct InputSample: Sendable {
    let type: CGEventType
    let keyCode: Int64
    let chars: String   // unicode string produced by a keyDown (layout-aware); "" otherwise
    let scroll: Int64
}

@MainActor
public final class InputSensor: Sensor {
    public let name = "input"
    private unowned let hub: SensorHub
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: Timer?

    private static let bufferCap = 4000            // flush a focus-session this long
    private static let contextReadCap = 10000      // read this much of the screen tail
    private static let qaKeepChars = 1500          // stored Q tail (raw — brain tick distills later)
    // A chat's Q is a whole conversation pane, not a terminal's last prompt: the
    // 1500-char terminal tail cuts the header off the top and leaves messages with
    // nobody attached to them. Measured: a full WhatsApp Web window is ~5 KB.
    // Raised 5000 -> 8000 with contextReadCap 6000 -> 10000. The old caps clipped
    // from the TAIL while the AX walk emits sidebar-then-pane and WhatsApp sorts the
    // chat list most-recent-first, so the clip ate the TOP of the sidebar — exactly
    // where the open thread's row lives, and exactly what the DREAM's sidebar-match
    // method needs. Headroom beats a splice heuristic: fewer moving parts to rot.
    private static let qaKeepCharsChat = 8000

    // AX window-walk budget. These were depth 12 / 150 elements / 0.4 s and that is
    // WHY 806 browser-chat exchanges captured only the bookmarks bar: measured on a
    // live WhatsApp Web window, the AXWebArea sits at depth 8 and the page needs
    // ~1,900 elements and depth ~30 before any message text appears — the walk died
    // ~150 elements in, having seen nothing but browser chrome, and kept the tail of
    // that. Cost is NOT the reason it was small: the same walk harvests 4,976 chars
    // in 0.18 s. (2026-08-05: setting AXEnhancedUserInterface/AXManualAccessibility
    // was tried and is unsupported by Chrome — rc -25208/-25205. The tree was never
    // dark; we were only ever looking at the first 150 nodes of it.)
    //
    // The deadline stays the real backstop, since a rich page (a big diff) can carry
    // >6,000 nodes. This runs once per answer-start on the MainActor, not per key.
    // Below this a "pane" is browser furniture, not a conversation.
    private static let paneMinChars = 400
    private static let windowWalkMaxDepth = 30
    private static let windowWalkMaxElements = 3000
    private static let windowWalkDeadline: TimeInterval = 1.0

    // Current aggregation window.
    private var winStart = Date()
    private var winApp = ""
    private var keystrokes = 0
    private var backspaces = 0
    private var clicks = 0
    private var scroll = 0
    private var textBuffer = ""
    private var contextSnapshot: String?           // screen captured at the start of a reply
    // WHO this window's typing is addressed to, captured at answer-start rather
    // than at flush: 30 s later the frontmost window may be something else
    // entirely, and an utterance attributed to the wrong conversation is worse
    // than one attributed to none.
    private var attribution: FocusContext?
    private var attributionRawTitle: String?
    // Which AX read produced the snapshot. Recorded rather than inferred so
    // "was this a real conversation pane?" is a fact at capture time, not a
    // guess the model has to make from length.
    private var contextSource: String?

    public init(hub: SensorHub) {
        self.hub = hub
    }

    public func start() throws {
        if !CGPreflightListenEventAccess() {
            SMLog.shared.warn(name, "input-monitoring-denied", [
                "hint": "System Settings → Privacy & Security → Input Monitoring → enable 2ndm1nd",
            ])
            _ = CGRequestListenEventAccess()
        }

        // No .mouseMoved: it fires thousands of times/sec and each event costs a
        // MainActor hop — clicks/scroll/keys are plenty for activity detection.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<InputSensor>.fromOpaque(ctx).takeUnretainedValue()
                // Extract scalars synchronously (CGEvent is only valid here), then
                // hop to the MainActor. Not assumeIsolated — the tap callback fires
                // on the run-loop thread, which may not present as the MainActor executor.
                if IsSecureEventInputEnabled() { return Unmanaged.passUnretained(event) }
                var typed = ""
                if type == .keyDown {
                    var length = 0
                    var buf = [UniChar](repeating: 0, count: 8)
                    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
                    if length > 0 { typed = String(utf16CodeUnits: buf, count: length) }
                }
                let sample = InputSample(
                    type: type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    chars: typed,
                    scroll: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                )
                Task { @MainActor in me.record(sample) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            SMLog.shared.error(name, "tap-create-failed")
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "CGEvent.tapCreate returned nil"])
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source

        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush(reason: "interval") }
        }
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        flushTimer?.invalidate()
    }

    private func record(_ s: InputSample) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front = frontApp?.bundleIdentifier ?? ""
        if front != winApp { flush(reason: "app-switch"); winApp = front; winStart = Date() }

        switch s.type {
        case .keyDown:
            keystrokes += 1
            if s.keyCode == 51 {                       // delete / backspace
                backspaces += 1
                if !textBuffer.isEmpty { textBuffer.removeLast() }
            } else {
                // Answer-start in a terminal/chat: snapshot the on-screen context
                // (the question) BEFORE the reply lands in it. Terminals expose
                // their scrollback as the focused element's value; chat apps
                // focus an (empty) input field, so fall back to reading the
                // WINDOW's text (ledger 2026-07-14: 490 terminal qa-exchanges
                // vs 2 chat — the conversation lives in sibling elements).
                if textBuffer.isEmpty, contextSnapshot == nil,
                   let pid = frontApp?.processIdentifier {
                    // One title read serves both jobs: deciding how to snapshot the
                    // question, and resolving WHO the answer is going to.
                    let title = frontWindowTitle(pid: pid)
                    let ctx = FocusContext.extract(bundleID: front, title: title)
                    attribution = ctx
                    attributionRawTitle = title
                    if ctx.family == "terminal" {
                        contextSnapshot = readFocusedText(pid: pid)
                    } else if ctx.family == "chat"
                        || (ctx.family == "browser" && FocusContext.webChatChannel(for: title) != nil) {
                        // READ THE PANE FIRST. The old order was
                        // `readFocusedText() ?? readWindowText()`, and in a chat the
                        // FOCUSED element is the message composer (or the omnibox), so
                        // the moment his first keystroke lands there it returns non-nil
                        // and the pane walk never runs. Measured over 13 days: 242 of
                        // 543 chat snapshots captured `web.whatsapp.com` and 123
                        // captured HIS OWN half-typed word as "the question" — 67%
                        // degenerate, and the `??` only fell through on the race where
                        // the character had not hit the field yet. The conversation was
                        // never dark; we were reading the wrong element.
                        let pane = readWindowText(pid: pid)
                        if let p = pane, p.count >= Self.paneMinChars {
                            contextSnapshot = p; contextSource = "pane"
                        } else {
                            let focused = readFocusedText(pid: pid)
                            contextSnapshot = focused ?? pane
                            contextSource = focused != nil ? "focused" : (pane != nil ? "pane-thin" : nil)
                        }
                    }
                }
                appendTyped(s.chars)
            }
            if textBuffer.count >= Self.bufferCap { flush(reason: "buffer-cap") }
        case .leftMouseDown, .rightMouseDown:
            clicks += 1
        case .scrollWheel:
            scroll += abs(Int(s.scroll))
        default:
            break
        }
    }

    /// Append the layout-produced characters, normalising line breaks and dropping
    /// non-printing control keys (arrows, escape, etc.) so the buffer reads as prose.
    private func appendTyped(_ chars: String) {
        for ch in chars {
            if ch == "\r" || ch == "\u{3}" { textBuffer.append("\n") }   // return / enter
            else if ch == "\t" || ch == "\n" { textBuffer.append(ch) }
            else if let sc = ch.unicodeScalars.first, sc.value >= 0x20 { textBuffer.append(ch) }
            // else: control character (arrow/esc/function key) — skip
        }
    }

    /// Read the focused UI element's text via Accessibility (the visible terminal /
    /// chat content). Timeout-guarded so an unresponsive app can't stall the tap.
    private func readFocusedText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elRef else { return nil }
        let el = elRef as! AXUIElement
        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success,
              let s = valRef as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // The question/prompt is usually near the bottom — keep the tail.
        return trimmed.count > Self.contextReadCap ? String(trimmed.suffix(Self.contextReadCap)) : trimmed
    }

    /// Title of the app's focused window (cheap AX read; nil on denial/timeout).
    private func frontWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }
        return titleRef as? String
    }

    /// Visible text of the focused WINDOW via a bounded AX-tree walk. Used for
    /// chat contexts, where the conversation sits in siblings of the focused
    /// input field. Tight caps (depth 12, 150 elements, 0.4 s wall clock) so a
    /// huge web page can't stall the tap thread; the suffix keeps the newest
    /// messages (AX tree order puts sidebars first, conversation last).
    private func readWindowText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return nil }
        var pieces: [String] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(Self.windowWalkDeadline)
        // AXHeading/AXCell carry the conversation header and list rows in web chats;
        // without them the walk sees message bodies but not who they belong to.
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell"]
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > Self.windowWalkMaxDepth || visited > Self.windowWalkMaxElements || Date() > deadline { return }
            visited += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, textRoles.contains(role) {
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success,
                   let s = valRef as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    pieces.append(s)
                }
            }
            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement] else { return }
            for k in kids { walk(k, depth + 1) }
        }
        walk(winRef as! AXUIElement, 0)
        let joined = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return nil }
        return joined.count > Self.contextReadCap ? String(joined.suffix(Self.contextReadCap)) : joined
    }

    private func flush(reason: String) {
        guard keystrokes + clicks + scroll > 0 else {
            winStart = Date(); textBuffer = ""; contextSnapshot = nil
            attribution = nil; attributionRawTitle = nil; contextSource = nil; return
        }
        // Snapshot everything, then reset — so the (possibly async) emit path can't
        // race the next aggregation window.
        let ts = Date().timeIntervalSince1970
        let duration = max(0.001, Date().timeIntervalSince(winStart))
        let ks = keystrokes, bs = backspaces, clk = clicks, scr = scroll
        let app = winApp
        let answer = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = contextSnapshot
        // Fall back to a flush-time resolve only when nothing was captured at
        // answer-start (pure activity windows, no typing).
        let attr = attribution ?? resolveAttributionNow(bundleID: app)
        let rawTitle = attributionRawTitle
        let ctxSource = contextSource
        // Switching conversation INSIDE one app changes the title but not the app, so
        // no flush fires and text typed to the second person would inherit the first
        // person's name. We cannot cheaply split the window, but we can refuse to
        // assert precision we do not have: re-read the title for conversation windows
        // only, and flag the utterance when it moved.
        var attrStale = false
        if let a = attr, a.family == "chat" || a.addresseeUnresolved,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == app,
           let nowTitle = frontWindowTitle(pid: front.processIdentifier),
           nowTitle != rawTitle {
            attrStale = true
        }
        keystrokes = 0; backspaces = 0; clicks = 0; scroll = 0
        textBuffer = ""; contextSnapshot = nil; attribution = nil; attributionRawTitle = nil
        contextSource = nil; winStart = Date()

        guard !hub.isNeverRecordApp(app) else { return }

        // Q/A path: a reply in a terminal/chat where we captured the on-screen question.
        if let ctxRaw = snapshot, !answer.isEmpty {
            emitQA(contextRaw: ctxRaw, answer: answer, app: app, attr: attr, rawTitle: rawTitle,
                   stale: attrStale, source: ctxSource, keystrokes: ks, duration: duration, ts: ts)
            return
        }

        // Default: per-app typed text + activity metrics.
        let cpm = Double(ks) * 60.0 / duration
        let bsRatio = ks > 0 ? Double(bs) / Double(ks) : 0
        var payload: [String: Any] = [
            "duration_s": duration, "keystrokes": ks, "chars_per_min": cpm,
            "backspace_ratio": bsRatio, "clicks": clk, "scroll": scr,
            "reason": reason,
        ]
        Self.stamp(attr, rawTitle: rawTitle, stale: attrStale, into: &payload)
        var text: String? = nil
        if !answer.isEmpty {
            payload["typed_len"] = answer.count
            // Attribution goes into the FTS text, not just the payload: retrieval
            // here is `brain search`, so an addressee that lives only in JSON is
            // invisible to the thing that has to find it.
            text = Self.prefix(attr) + answer
        }
        hub.emit(SMEvent(
            ts: ts, source: "input", kind: "activity-window",
            app: app.isEmpty ? nil : app, text: text, payload: payload
        ))
    }

    /// Best-effort attribution for a window we never saw an answer start in.
    ///
    /// The bundle-id guard is load-bearing, not defensive: `record()` flushes the
    /// OLD window before it updates `winApp`, so at an app-switch flush `app` is the
    /// app being left while `frontmostApplication` is the one being entered. Reading
    /// the new app's title and labelling the old app's utterance with it produced
    /// exactly the failure this whole change exists to prevent — a confident,
    /// wrong addressee. Silence beats a wrong name.
    private func resolveAttributionNow(bundleID: String) -> FocusContext? {
        guard !bundleID.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID
        else { return nil }
        return FocusContext.extract(bundleID: bundleID, title: frontWindowTitle(pid: front.processIdentifier))
    }

    /// Copy the attribution onto an event payload — the derived label AND the raw
    /// evidence it came from.
    ///
    /// `win_title` verbatim is the important half. The derived fields are only ever
    /// today's best guess; when a better rule exists tomorrow, every event already
    /// captured must be re-derivable, and it can only be re-derived from the raw
    /// title. Storing the interpretation without its input is what makes a labelling
    /// system unfixable — the label freezes and the evidence is gone.
    private static func stamp(_ attr: FocusContext?, rawTitle: String?, stale: Bool,
                              into payload: inout [String: Any]) {
        if let rawTitle, !rawTitle.isEmpty { payload["win_title"] = rawTitle }
        if stale { payload["attribution_stale"] = true }
        guard let attr else { return }
        payload["channel"] = attr.channel
        if let to = attr.to { payload["to"] = to }
        if let thread = attr.thread { payload["thread"] = thread }
        if attr.addresseeUnresolved { payload["addressee_unresolved"] = true }
    }

    /// What the "question" in a Q/A actually IS, decided from the read that produced
    /// it rather than guessed later from length. This is the metric the brain grades
    /// its own capture on, and the rule it needs: an event whose pane_kind is not
    /// `full` has no conversation in it, so no addressee may be inferred from it.
    /// Before 2026-08-18, 67% of chat events were `url-only` or `composer` and nothing
    /// said so — the model saw a short Q and had to guess whether that meant a quiet
    /// screen or a blind sensor.
    private static func paneKind(source: String?, context: String) -> String? {
        guard let source else { return nil }
        switch source {
        case "pane":      return "full"
        case "pane-thin": return "thin"
        default:
            let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.contains("\n"), t.count < 60,
               t.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return "url-only"
            }
            return "composer"
        }
    }

    /// A searchable one-line header so FTS can answer "what did I say to X".
    ///
    /// Only ever emitted for a RESOLVED addressee. `text` is the verbatim ledger and
    /// FTS indexes only that column, so anything synthetic written here is permanent
    /// and unfixable: a "(unresolved) [whatsapp-web]" line would make every future
    /// search for "whatsapp" match 800 events that say nothing. The unresolved case
    /// is carried by the payload flag, where it can be superseded.
    private static func prefix(_ attr: FocusContext?) -> String {
        guard let attr, let to = attr.to, !to.isEmpty else { return "" }
        return "TO: \(to) [\(attr.channel)]\n"
    }

    // MARK: - Q/A exchange (raw persist — the brain tick does the LLM work)

    private func emitQA(contextRaw: String, answer: String, app: String, attr: FocusContext?,
                        rawTitle: String?, stale: Bool, source: String?,
                        keystrokes: Int, duration: Double, ts: Double) {
        let ctx = Self.collapse(contextRaw)
        // Keep the whole conversation pane for a chat; a terminal still keeps a tail.
        // Deliberately NO parsing of who the header names — capture stays dumb and
        // verbatim, and the brain resolves the addressee in batch from this evidence.
        // A WhatsApp-shaped extraction rule written here would be a rule only a human
        // could ever change.
        let family = attr?.family ?? FocusContext.family(of: app)
        let isConversation = family == "chat" || (attr?.addresseeUnresolved ?? false)
        let keep = isConversation ? Self.qaKeepCharsChat : Self.qaKeepChars
        let q = ctx.count > keep ? String(ctx.suffix(keep)) : ctx
        var payload: [String: Any] = [
            "app_family": FocusContext.family(of: app),
            "q_len": ctx.count,
            "keystrokes": keystrokes, "duration_s": duration,
        ]
        Self.stamp(attr, rawTitle: rawTitle, stale: stale, into: &payload)
        if let kind = Self.paneKind(source: source, context: ctx) { payload["pane_kind"] = kind }
        hub.emit(SMEvent(
            ts: ts, source: "input", kind: "qa-exchange",
            app: app.isEmpty ? nil : app,
            text: "\(Self.prefix(attr))Q: \(q)\nA: \(answer)",
            payload: payload
        ))
    }

    /// Collapse blank-line runs and trailing spaces so terminal scrollback is compact.
    private static func collapse(_ s: String) -> String {
        var out: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
