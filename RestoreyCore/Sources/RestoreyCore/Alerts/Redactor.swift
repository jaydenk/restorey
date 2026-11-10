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
public struct Redactor: Sendable {
    private static let placeholder = "[redacted]"

    private let secrets: [String]
    private let checkInHosts: [String]

    /// - Parameter checkInURLs: the user's own check-in URLs; the path after each host is redacted.
    public init(secrets: [String], checkInURLs: [String] = []) {
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
        var out = s
        if !secrets.isEmpty {
            let alternation = secrets.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            out = Self.replace(alternation, in: out, with: Self.placeholder)
        }
        // Before the userinfo pass, so `https://x@hc-ping.com/<id>` still loses its id.
        for host in checkInHosts {
            let pattern =
                #"(https?://(?:[^/\s"']*@)?(?:[A-Za-z0-9\-]+\.)*"# + NSRegularExpression.escapedPattern(for: host)
                + #"(?::\d+)?)/[^"'),>;\s]*"#
            out = Self.replace(pattern, in: out, with: "$1/\(Self.placeholder)", caseInsensitive: true)
        }
        return Self.replace(
            #"([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s"']*@"#, in: out, with: "$1\(Self.placeholder)@")
    }

    private static func replace(
        _ pattern: String, in s: String, with template: String, caseInsensitive: Bool = false
    ) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
