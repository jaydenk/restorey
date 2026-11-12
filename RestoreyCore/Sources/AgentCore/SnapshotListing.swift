import Foundation
import RestoreyCore

/// Reads `restic snapshots --json` output (one JSON array on one line) into what `adopt` reports.
enum SnapshotListing {
    struct Entry: Decodable {
        let time: String
        let hostname: String
        let paths: [String]
    }

    /// True for the line that carries the listing; restic prints nothing else starting with `[`.
    static func isListing(_ line: String) -> Bool { line.hasPrefix("[") }

    /// Every host, sorted; the paths of the newest snapshot whose host is `hostLabel` (empty when that
    /// host has none); and the total count. Throws when `line` is not a snapshot listing.
    static func report(from line: String, hostLabel: String) throws -> AdoptReport {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(line.utf8))
        let newest = entries.filter { $0.hostname == hostLabel }
            .max { (date($0.time) ?? .distantPast) < (date($1.time) ?? .distantPast) }
        return AdoptReport(
            hosts: Set(entries.map(\.hostname)).sorted(),
            latestPathsForHost: newest?.paths ?? [],
            snapshotCount: entries.count)
    }

    /// restic writes RFC 3339 with up to nine fractional digits (`2026-11-11T03:11:48.216226123+10:30`);
    /// the formatter takes at most three, so the rest are dropped.
    static func date(_ text: String) -> Date? {
        var trimmed = text
        if let dot = text.firstIndex(of: "."),
            let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber })
        {
            let digits = text[text.index(after: dot)..<end].prefix(3)
            trimmed = String(text[..<dot]) + (digits.isEmpty ? "" : "." + digits) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = trimmed.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
