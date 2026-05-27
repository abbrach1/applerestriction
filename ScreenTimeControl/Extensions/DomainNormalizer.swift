import Foundation

/// Collapses any of the variants an admin might type
/// ("https://www.youtube.com/", "*.youtube.com", "Youtube.com")
/// to a single canonical form: lowercase host with no scheme,
/// wildcards, www., port, or path. Returns nil for empty input.
enum DomainNormalizer {
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        while s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        if s.hasPrefix("*") { s = String(s.dropFirst()) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }

        for sep in ["/", "?", "#", ":"] {
            if let idx = s.firstIndex(of: Character(sep)) { s = String(s[..<idx]) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return s.isEmpty ? nil : s
    }
}
