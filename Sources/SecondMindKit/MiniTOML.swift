// MiniTOML — the deliberately tiny TOML subset reader for 2ndMind config.
//
// Supports exactly what config.toml uses (same contract as v1's cfg.sh, with
// the v1 bug class fixed by design):
//   [section] / [section.sub] headers
//   key = "basic string"   — comments after the closing quote are stripped
//   key = 'literal string' — backslashes pass through verbatim (regex-safe)
//   key = bare / number / true / false
//   key = ["a", "b"] and multi-line arrays
//
// NOT supported (on purpose): inline tables, nested arrays, escapes beyond
// \" inside basic strings, dates. The config schema avoids those.

import Foundation

public struct MiniTOML: Sendable {
    private let scalars: [String: String]
    private let arrays: [String: [String]]

    public init(string: String) {
        var scalars: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var section = ""
        var pendingArrayKey: String? = nil
        var pendingArray: [String] = []

        for rawLine in string.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let key = pendingArrayKey {
                // Inside a multi-line array: accumulate until `]`.
                if let close = trimmed.firstIndex(of: "]") {
                    pendingArray.append(contentsOf: Self.splitArrayItems(String(trimmed[..<close])))
                    arrays[key] = pendingArray
                    pendingArrayKey = nil
                    pendingArray = []
                } else {
                    pendingArray.append(contentsOf: Self.splitArrayItems(trimmed))
                }
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let fullKey = section.isEmpty ? key : "\(section).\(key)"

            if rawValue.hasPrefix("[") {
                let inner = String(rawValue.dropFirst())
                if let close = inner.firstIndex(of: "]") {
                    arrays[fullKey] = Self.splitArrayItems(String(inner[..<close]))
                } else {
                    pendingArrayKey = fullKey
                    pendingArray = Self.splitArrayItems(inner)
                }
            } else {
                scalars[fullKey] = Self.parseScalar(rawValue)
            }
        }
        if let key = pendingArrayKey { arrays[key] = pendingArray } // unterminated array: keep what we got
        self.scalars = scalars
        self.arrays = arrays
    }

    public init(contentsOf url: URL) throws {
        self.init(string: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Accessors

    public func string(_ key: String) -> String? { scalars[key] }
    public func int(_ key: String) -> Int? { scalars[key].flatMap(Int.init) }
    public func double(_ key: String) -> Double? { scalars[key].flatMap(Double.init) }
    public func bool(_ key: String) -> Bool? {
        switch scalars[key] { case "true": true; case "false": false; default: nil }
    }
    public func array(_ key: String) -> [String]? { arrays[key] }

    /// Scalar with `~` expanded to the user's home directory.
    public func path(_ key: String) -> String? { scalars[key].map(Self.expandTilde) }
    public func paths(_ key: String) -> [String]? { arrays[key]?.map(Self.expandTilde) }

    public static func expandTilde(_ p: String) -> String {
        if p == "~" { return NSHomeDirectory() }
        if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
        return p
    }

    // MARK: - Parsing internals

    /// The v1 lesson, encoded: a quoted value is the content of its FIRST quote
    /// pair — anything after the closing quote (e.g. an inline comment) is
    /// discarded. Single quotes are TOML literal strings: verbatim, regex-safe.
    static func parseScalar(_ raw: String) -> String {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped { out.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" { return out }
                out.append(ch)
            }
            return out // unterminated: best effort
        }
        if raw.hasPrefix("'") {
            let inner = raw.dropFirst()
            if let close = inner.firstIndex(of: "'") { return String(inner[..<close]) }
            return String(inner)
        }
        // Bare value: strip trailing comment, then whitespace.
        if let hash = raw.firstIndex(of: "#") {
            return String(raw[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Split a single-line run of array items: `"a", 'b', c`.
    static func splitArrayItems(_ run: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inBasic = false, inLiteral = false, escaped = false
        for ch in run {
            if inBasic {
                if escaped { current.append(ch); escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inBasic = false }
                else { current.append(ch) }
            } else if inLiteral {
                if ch == "'" { inLiteral = false } else { current.append(ch) }
            } else if ch == "\"" { inBasic = true }
            else if ch == "'" { inLiteral = true }
            else if ch == "," { items.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else if ch == "#" { break } // comment after items
            else { current.append(ch) }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { items.append(last) }
        return items.filter { !$0.isEmpty }
    }
}
