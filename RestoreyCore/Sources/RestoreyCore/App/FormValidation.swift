import Foundation

/// The checks the setup flow and Settings share (UI design §5, §6). Each `String?` is the sentence shown
/// under the field, or nil when the text is fine. Pure: no field, window or agent is involved. The agent
/// validates again on save (`Plan.validationErrors`); this only spares the user a round trip.
public enum FormValidation {
    /// A refused upload limit: the sentence to show. (`Result` needs an `Error`, and a bare `String` isn't one.)
    public struct Problem: Error, Equatable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public init(stringLiteral value: String) { message = value }
        public var description: String { message }
    }

    /// S3-style bucket naming, the common ground of AWS S3, Backblaze B2 and the S3-compatible stores:
    /// 3 to 63 characters of lower case letters, digits, hyphens and dots. Spaces around the text are a
    /// pasting slip and are ignored (`trimmed` is what gets saved); capitals and inner spaces are the
    /// usual real mistake and get their own sentence.
    public static func bucket(_ text: String) -> String? {
        let bucket = trimmed(text)
        if bucket.isEmpty { return "Enter the bucket name." }
        if bucket.contains(where: { $0.isWhitespace || $0.isUppercase }) {
            return "Bucket names are lower case, without spaces."
        }
        let allowed = bucket.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar))
                || scalar == "-" || scalar == ".")
        }
        guard allowed, (3...63).contains(bucket.count) else {
            return "Bucket names are 3 to 63 characters of lower case letters, numbers, hyphens and dots."
        }
        return nil
    }

    /// The endpoint as it is saved: trimmed, `https://` added when there is no scheme, the scheme and host
    /// lower-cased, any trailing slash dropped. Nil when `endpoint(_:)` refuses it.
    public static func normalisedEndpoint(_ text: String) -> String? {
        guard endpoint(text) == nil else { return nil }
        let withScheme = withScheme(trimmed(text))
        guard var components = URLComponents(string: withScheme) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        return components.string
    }

    /// An S3 endpoint: a web address, `https://` assumed when no scheme is typed. `http://` is allowed for
    /// a store on the local network; any other scheme is refused.
    public static func endpoint(_ text: String) -> String? {
        let typed = trimmed(text)
        if typed.isEmpty { return "Enter the endpoint." }
        if let range = typed.range(of: "://") {
            let scheme = typed[..<range.lowerBound].lowercased()
            guard scheme == "https" || scheme == "http" else {
                return "The endpoint must start with https:// or http://."
            }
        }
        let address = withScheme(typed)
        guard let components = URLComponents(string: address), let host = components.host, !host.isEmpty,
            !host.contains(where: \.isWhitespace)
        else { return "That endpoint isn't a web address." }
        return nil
    }

    /// The name restic records on every snapshot. Anything on one line will do.
    public static func hostLabel(_ text: String) -> String? {
        let label = trimmed(text)
        if label.isEmpty { return "The host label can't be empty." }
        if label.contains(where: \.isNewline) { return "The host label must be on one line." }
        return nil
    }

    /// The upload limit as typed, in MB/s, to what is stored, in KiB/s: "" is no limit (nil), "5" is 5120,
    /// "1.5" is 1536 (one MB/s here is 1024 KiB/s, the unit restic's `--limit-upload` takes). Only a plain
    /// decimal number with a full stop is read, so the result never depends on the Mac's region.
    public static func uploadLimit(_ text: String) -> Result<Int?, Problem> {
        let typed = trimmed(text)
        if typed.isEmpty { return .success(nil) }
        let notANumber: Problem = "Enter the limit as a number of MB/s, such as 5 or 1.5."
        guard typed.wholeMatch(of: /-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)/) != nil,
            let megabytes = Decimal(string: typed, locale: Locale(identifier: "en_US_POSIX"))
        else { return .failure(notANumber) }
        let kiB = NSDecimalNumber(decimal: megabytes * 1024).rounding(accordingToBehavior: nil)
        guard kiB.doubleValue < Double(Int32.max) else { return .failure(notANumber) }
        guard kiB.intValue >= 1 else {
            return .failure("The upload limit must be more than 0 MB/s. Leave it empty for no limit.")
        }
        return .success(kiB.intValue)
    }

    /// What is shown when `addingFileTypes` rejects an entry.
    public static let fileTypeProblem = "Give the extension alone, such as dmg or tar.gz, with no leading dot, slash or wildcard."

    /// Adds the file types typed or pasted into the field (separated by commas, spaces or new lines) to the
    /// list: each normalised by `Plan.normalisedFileType`, an entry already listed skipped, and each entry
    /// that isn't a bare extension returned in `rejected`, as typed, rather than added.
    public static func addingFileTypes(_ text: String, to existing: [String]) -> (types: [String], rejected: [String]) {
        var types = existing
        var rejected: [String] = []
        for entry in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) {
            guard let type = Plan.normalisedFileType(entry) else { rejected.append(entry); continue }
            if !types.contains(type) { types.append(type) }
        }
        return (types, rejected)
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func withScheme(_ typed: String) -> String { typed.contains("://") ? typed : "https://" + typed }
}
