import Foundation

/// Normalizes domain entries (admin input, child input, etc.) and tests whether
/// a navigation host matches a list rule. Tolerant of `https://`, paths,
/// trailing slashes, ports, query strings, and leading `www.` — so "youtube.com",
/// "www.youtube.com", "https://youtube.com/", etc. all collapse to "youtube.com".
enum DomainMatcher {

    /// Normalizes a raw domain entry to a bare host (lowercase, no protocol,
    /// no `www.` prefix, no path/port/query). Returns nil for empty input.
    static func normalize(_ raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let r = s.firstIndex(of: "/") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: "?") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: "#") { s = String(s[..<r]) }
        if let r = s.firstIndex(of: ":") { s = String(s[..<r]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.isEmpty ? nil : s
    }

    /// True if `host` equals or is a subdomain of `rule` (after normalizing both).
    static func matches(host: String, rule: String) -> Bool {
        guard let h = normalize(host), let r = normalize(rule) else { return false }
        return h == r || h.hasSuffix(".\(r)")
    }

    /// True if `host` matches any entry in `rules`.
    static func matches(host: String, anyOf rules: [String]) -> Bool {
        guard let h = normalize(host) else { return false }
        for entry in rules {
            guard let r = normalize(entry) else { continue }
            if h == r || h.hasSuffix(".\(r)") { return true }
        }
        return false
    }
}
