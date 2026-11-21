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
    /// 3 to 63 characters of lower case letters, digits, hyphens and dots, starting and ending with a letter
    /// or digit, with no `..` and not shaped like an IPv4 address. Spaces around the text are a pasting slip
    /// and are ignored; capitals and inner spaces are the usual real mistake and get their own sentence.
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
        if "-.".contains(bucket.first!) || "-.".contains(bucket.last!) {
            return "Bucket names can’t start or end with a hyphen or a dot."
        }
        if bucket.contains("..") { return "Bucket names can’t have two dots in a row." }
        if bucket.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) != nil {
            return "Bucket names can’t look like an IP address."
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

    /// An S3 endpoint: just the server address (and port), `https://` assumed when no scheme is typed.
    /// `http://` is for a store on this Mac, the local network or Tailscale only (`isLocalHost`). A path, user info, query or fragment
    /// is refused: a path would be misread as the bucket, and user info would put a secret in `config.json`.
    public static func endpoint(_ text: String) -> String? {
        let typed = trimmed(text)
        if typed.isEmpty { return "Enter the endpoint." }
        let schemeProblem = "The endpoint must start with https:// or http://."
        if let range = typed.range(of: "://") {
            let scheme = typed[..<range.lowerBound].lowercased()
            guard scheme == "https" || scheme == "http" else { return schemeProblem }
        } else if typed.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:(?![0-9]+(?:\/|$))/) != nil {
            // "https:/host", "ftp:x": a scheme-like start that isn't a host and port ("host:9000").
            return schemeProblem
        }
        guard let components = URLComponents(string: withScheme(typed)), let host = components.host, !host.isEmpty,
            !host.contains(where: \.isWhitespace)
        else { return "That endpoint isn’t a web address." }
        if components.user != nil || components.password != nil {
            return "Leave the user name and password out of the endpoint: the access keys have their own fields."
        }
        if components.query != nil || components.fragment != nil {
            return "The endpoint is just the server address, with no ? or #."
        }
        if !components.path.isEmpty, components.path != "/" {
            return "Leave the folder out of the endpoint: the bucket and prefix have their own fields."
        }
        if components.scheme?.lowercased() == "http", !isLocalHost(host) {
            return "http:// is only for a store on this Mac, your local network or Tailscale. Use https:// for anything else."
        }
        return nil
    }

    /// A host `http://` is accepted for: one that stays on this Mac, the local network or the user's tailnet.
    /// That is localhost; a loopback, private (10/8, 172.16/12, 192.168/16), link-local (169.254/16) or Tailscale
    /// (100.64.0.0/10) IPv4 address; an IPv6 loopback, link-local (fe80::/10) or unique local (fc00::/7)
    /// address; a name ending in `.local`, `.localhost`, `.lan`, `.home.arpa`, `.internal` or `.ts.net`; or a
    /// name with no dots. Every other host needs `https://`.
    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        for suffix in [".local", ".localhost", ".lan", ".home.arpa", ".internal", ".ts.net"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") {
            guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
                let hextet = Int(first, radix: 16)
            else { return false }
            return (0xfe80...0xfebf).contains(hextet) || (0xfc00...0xfdff).contains(hextet)
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            let o = octets.map { $0! }
            return o[0] == 10 || o[0] == 127 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1]))
                || (o[0] == 169 && o[1] == 254) || (o[0] == 100 && (64...127).contains(o[1]))
        }
        return !host.contains(".")
    }

    /// The name restic records on every snapshot. Anything on one line will do.
    public static func hostLabel(_ text: String) -> String? {
        let label = trimmed(text)
        if label.isEmpty { return "The host label can’t be empty." }
        if label.contains(where: \.isNewline) { return "The host label must be on one line." }
        return nil
    }

    /// A new repository's password as typed: nil, or the sentence to show. restic trims whitespace from the output of
    /// `RESTIC_PASSWORD_COMMAND`, which is how Restorey hands it the password, so one that starts or ends with a space
    /// (or a tab or newline) would reach restic without it and never open the repository again. Inner spaces are fine.
    /// An empty field has no sentence of its own here: setup keeps its button disabled instead.
    public static func newRepositoryPassword(_ password: String) -> String? {
        guard let first = password.first, let last = password.last else { return nil }
        if first.isWhitespace || last.isWhitespace { return "A password can’t start or end with a space." }
        return nil
    }

    /// The upload limit as typed, in `unit` (MB/s or KB/s), to what is stored, in KiB/s: "" is no limit (nil), "5"
    /// MB/s is 5120, "1.5" is 1536 (one MB/s here is 1024 KiB/s, the unit restic's `--limit-upload` takes), "512"
    /// KB/s is 512. Only a plain decimal number with a full stop is read, so the result never depends on the Mac's
    /// region.
    ///
    /// `emptyMeansNone` is false where an empty amount is refused and None is how to say no limit (the Mac-wide
    /// limit); only the wording for 0 differs.
    public static func uploadLimit(
        _ text: String, unit: UploadLimitUnit = .megabytes, emptyMeansNone: Bool = true
    ) -> Result<Int?, Problem> {
        let typed = trimmed(text)
        if typed.isEmpty { return .success(nil) }
        let notANumber = limitNotANumber(unit)
        guard typed.wholeMatch(of: /-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)/) != nil,
            let amount = Decimal(string: typed, locale: Locale(identifier: "en_US_POSIX"))
        else { return .failure(notANumber) }
        let perUnit: Decimal = unit == .megabytes ? 1024 : 1
        let kiB = NSDecimalNumber(decimal: amount * perUnit).rounding(accordingToBehavior: nil)
        guard kiB.doubleValue < Double(Int32.max) else { return .failure(notANumber) }
        guard kiB.intValue >= 1 else {
            let instead = emptyMeansNone ? "Leave it empty for no limit." : "Choose None for no limit."
            return .failure(Problem("The upload limit must be more than 0 \(unitName(unit)). \(instead)"))
        }
        return .success(kiB.intValue)
    }

    /// What to say when a limit isn't a number (or isn't there).
    public static func limitNotANumber(_ unit: UploadLimitUnit) -> Problem {
        switch unit {
        case .megabytes: "Enter the limit as a number of MB/s, such as 5 or 1.5."
        case .kilobytes: "Enter the limit as a number of KB/s, such as 512."
        }
    }

    /// A percentage of the measured upload speed, as typed: a whole number from 1 to 100.
    public static func percent(_ text: String) -> Result<Int, Problem> {
        let typed = trimmed(text)
        guard typed.wholeMatch(of: /[0-9]{1,3}/) != nil, let value = Int(typed), (1...100).contains(value) else {
            return .failure("Enter a percentage from 1 to 100.")
        }
        return .success(value)
    }

    /// "MB/s" or "KB/s".
    public static func unitName(_ unit: UploadLimitUnit) -> String {
        switch unit {
        case .megabytes: "MB/s"
        case .kilobytes: "KB/s"
        }
    }

    /// A saved upload limit as the field shows it, in `unit`: the inverse of `uploadLimit`. MB/s has up to two
    /// decimals and a full stop whatever the Mac's region; KB/s is whole. nil (no limit) is empty. A limit that
    /// needs more decimals is shown rounded, so a form keeps the stored value unless the text is changed
    /// (`PlanEdit`).
    public static func uploadLimitText(kiB: Int?, unit: UploadLimitUnit = .megabytes) -> String {
        guard let kiB else { return "" }
        if unit == .kilobytes { return String(kiB) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: Double(kiB) / 1024)) ?? "\(Double(kiB) / 1024)"
    }

    /// The exact KiB/s behind a limit's text, kept when a unit switch rewrote the text (the text shows 100 KB/s as
    /// "0.1" MB/s, which is 102). It counts only while the text is still the one the switch wrote: typing makes the
    /// text what it says.
    public struct ExactLimit: Sendable, Equatable {
        public var text: String
        public var kiB: Int
        public init(text: String, kiB: Int) {
            self.text = text
            self.kiB = kiB
        }
    }

    /// The limit as typed, in KiB/s: `exact` when the text is still the one it was written for, else as typed.
    public static func limitKiB(
        _ text: String, unit: UploadLimitUnit, exact: ExactLimit?, emptyMeansNone: Bool = true
    ) -> Result<Int?, Problem> {
        if let exact, exact.text == text { return .success(exact.kiB) }
        return uploadLimit(text, unit: unit, emptyMeansNone: emptyMeansNone)
    }

    /// A typed limit shown again in another unit, so switching from 5 MB/s to KB/s reads 5120, not 5, without
    /// changing the stored value: the KiB/s it stands for goes with the new text as `exact`. Text that isn't a limit
    /// (empty, or not a number) is left as it is.
    public static func convertedLimit(
        _ text: String, exact: ExactLimit?, from old: UploadLimitUnit, to new: UploadLimitUnit
    ) -> (text: String, exact: ExactLimit?) {
        guard old != new, case .success(let kiB?) = limitKiB(text, unit: old, exact: exact) else { return (text, exact) }
        let shown = uploadLimitText(kiB: kiB, unit: new)
        return (shown, ExactLimit(text: shown, kiB: kiB))
    }

    /// `convertedLimit`'s text alone.
    public static func convertedLimitText(_ text: String, from old: UploadLimitUnit, to new: UploadLimitUnit) -> String {
        convertedLimit(text, exact: nil, from: old, to: new).text
    }

    /// A sentence in the agent's style (no closing full stop: `fileTypeProblem`, `AgentError`, the call
    /// errors) as a form shows it, with this type's sentences: ending with a full stop. Text that already
    /// ends with one, a question mark or an exclamation mark is left alone.
    public static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".?!".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// What is shown for entries `addingFileTypes` rejected. The wording the agent uses when it refuses a plan
    /// with such an entry (`AgentError`), from this one place.
    public static func fileTypeProblem(rejected: [String]) -> String {
        let quoted = rejected.map { "“\($0)”" }.joined(separator: ", ")
        let subject = rejected.count == 1 ? "\(quoted) isn’t a file type" : "\(quoted) aren’t file types"
        return "\(subject) to exclude: give the extension alone, such as dmg or tar.gz, with no leading dot, slash, wildcard or space"
    }

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

    /// `existing` followed by each new path that isn't already in it. Paths are compared as written, by string
    /// handling alone (`SourcePaths`): `/tmp` and `/private/tmp`, a trailing slash and `..` all count as one, but a link
    /// and where it leads are two paths: links are never followed. It never reads the disk, since the app runs it on
    /// its main actor (L157); adding folders also compares where links lead, off the main actor (`FolderDrop.look`). A
    /// path is stored in its standardised form (no trailing slash).
    public static func addingSources(_ paths: [String], to existing: [String]) -> [String] {
        var result = existing
        for path in paths {
            let standard = SourcePaths.standardised(path)
            if !result.contains(where: { SourcePaths.sameFirmlinkSpelling($0, standard) }) { result.append(standard) }
        }
        return result
    }

    /// A source path as shown in the list: `~` for the home folder.
    public static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func withScheme(_ typed: String) -> String { typed.contains("://") ? typed : "https://" + typed }
}
