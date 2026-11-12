import Foundation

/// Removes secrets from text before it reaches a log or the body of a `/fail` ping.
///
/// - Secrets are replaced with `[redacted]` in a single pass, longest first, so a secret that contains
///   another is removed whole and a short secret (`act`) cannot re-match inside an inserted
///   placeholder. Blank secrets are ignored (they would match everything). Each secret is also matched
///   in its whitespace-trimmed form, and every form in its percent-encoded (upper and lower case),
///   form-encoded (`+` for space) and base64 (standard and URL-safe) variants, because secrets show
///   up inside URLs and headers.
/// - For `hc-ping.com` and any configured check-in URL, everything after the host is replaced. The path
///   is the check's identifier, which is itself the secret. It stops at a quote, `)`, `>`, `,`, `;`
///   or whitespace so the rest of a JSON or prose line survives.
/// - URL userinfo is removed in any scheme, up to the last `@` before the first `/`:
///   `https://user:pass@host` becomes `https://[redacted]@host`.
///
/// The patterns are compiled once, in `init`. It fails closed (final review M3): if the secrets' pattern
/// can't be compiled, secrets are replaced by a literal single-pass scan instead, and if a fixed pattern
/// (check-in path, userinfo) can't be, the whole text is replaced by `[redacted]`. Unredacted text never
/// comes out.
public struct Redactor: Sendable {
    static let placeholder = "[redacted]"

    /// Compiles a pattern; tests pass one that fails, to reach the fallbacks.
    typealias Compile = @Sendable (_ pattern: String, _ options: NSRegularExpression.Options) throws -> NSRegularExpression

    private let secrets: [String]
    private let checkInHosts: [String]
    /// The secrets' alternation, nil when there are none or it couldn't be compiled.
    private let secretPattern: NSRegularExpression?
    /// The check-in path patterns, then the userinfo pattern; nil when any couldn't be compiled.
    private let fixedPatterns: [NSRegularExpression]?

    /// - Parameter checkInURLs: the user's own check-in URLs; the path after each host is redacted.
    public init(secrets: [String], checkInURLs: [String] = []) {
        self.init(secrets: secrets, checkInURLs: checkInURLs, compile: { try NSRegularExpression(pattern: $0, options: $1) })
    }

    init(secrets: [String], checkInURLs: [String], compile: Compile) {
        var variants: Set<String> = []
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            for form in [secret, trimmed] { variants.formUnion(Self.variants(of: form)) }
        }
        // Longest first; ties broken alphabetically so the result is deterministic.
        self.secrets = variants.sorted { ($0.count, $1) > ($1.count, $0) }

        var hosts: [String] = ["hc-ping.com"]
        for url in checkInURLs {
            if let host = URLComponents(string: url)?.host, !host.isEmpty { hosts.append(host.lowercased()) }
        }
        self.checkInHosts = Array(Set(hosts)).sorted()

        let alternation = self.secrets.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        secretPattern = self.secrets.isEmpty ? nil : try? compile(alternation, [])
        var fixed: [NSRegularExpression]? = []
        for host in checkInHosts {
            // Before the userinfo pass, so `https://x@hc-ping.com/<id>` still loses its id.
            let pattern =
                #"(https?://(?:[^/\s"']*@)?(?:[A-Za-z0-9\-]+\.)*"# + NSRegularExpression.escapedPattern(for: host)
                + #"(?::\d+)?)/[^"'),>;\s]*"#
            if let regex = try? compile(pattern, [.caseInsensitive]) { fixed?.append(regex) } else { fixed = nil }
        }
        if let userinfo = try? compile(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s"']*@"#, []) {
            fixed?.append(userinfo)
        } else {
            fixed = nil
        }
        fixedPatterns = fixed
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Every encoder differs in what it leaves alone, so cover the common ones.
    private static let encodingSets: [CharacterSet] = [
        unreserved, .urlUserAllowed, .urlPasswordAllowed, .urlQueryAllowed, .urlPathAllowed,
    ]

    private static func variants(of secret: String) -> Set<String> {
        var out: Set<String> = [secret]
        var encodings: [String] = []
        for allowed in encodingSets {
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: allowed) {
                encodings.append(encoded)
            }
        }
        if let form = secret.addingPercentEncoding(withAllowedCharacters: unreserved) {
            encodings.append(form.replacingOccurrences(of: "%20", with: "+"))
        }
        for encoded in encodings {
            out.insert(encoded)
            out.insert(lowercasingPercentEscapes(encoded))
        }
        let base64 = Data(secret.utf8).base64EncodedString()
        out.insert(base64)
        out.insert(base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
        return out
    }

    /// `%2F` to `%2f`, leaving every other character alone.
    private static func lowercasingPercentEscapes(_ s: String) -> String {
        var result = ""
        var remaining = 0
        for ch in s {
            if remaining > 0 {
                result.append(contentsOf: ch.lowercased())
                remaining -= 1
            } else {
                result.append(ch)
                if ch == "%" { remaining = 2 }
            }
        }
        return result
    }

    public func redact(_ s: String) -> String {
        // A fixed pattern that didn't compile: nothing can say what is safe to keep.
        guard let fixedPatterns else { return Self.placeholder }
        var out = s
        if let secretPattern {
            out = Self.replace(secretPattern, in: out, with: Self.placeholder)
        } else if !secrets.isEmpty {
            out = Self.literalRedaction(out, secrets: secrets)
        }
        for (index, regex) in fixedPatterns.enumerated() {
            let isUserinfo = index == fixedPatterns.count - 1
            out = Self.replace(regex, in: out, with: isUserinfo ? "$1\(Self.placeholder)@" : "$1/\(Self.placeholder)")
        }
        return out
    }

    /// The same single pass as the alternation, without a regular expression: at each position the
    /// longest secret that starts there (`secrets` is longest first) is replaced, and the scan carries on
    /// after it, so a short secret can't match inside an inserted placeholder.
    static func literalRedaction(_ s: String, secrets: [String]) -> String {
        var out = ""
        var index = s.startIndex
        while index < s.endIndex {
            if let secret = secrets.first(where: { s[index...].hasPrefix($0) }) {
                out += placeholder
                index = s.index(index, offsetBy: secret.count)
            } else {
                out.append(s[index])
                index = s.index(after: index)
            }
        }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
