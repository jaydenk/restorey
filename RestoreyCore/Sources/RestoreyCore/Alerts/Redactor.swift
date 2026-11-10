import Foundation

/// Removes secrets from text before it reaches a log or the body of a `/fail` ping.
///
/// - Each secret is replaced with `[redacted]`, longest first so a secret that contains another is
///   removed whole. Its percent-encoded forms are redacted too, because secrets show up inside URLs.
///   Empty and whitespace-only secrets are ignored (they would match everything).
/// - URL userinfo is removed in any scheme: `https://user:pass@host` becomes `https://[redacted]@host`.
/// - For `hc-ping.com` and any configured check-in URL, everything after the host is replaced. The path
///   is the check's identifier, which is itself the secret.
public struct Redactor: Sendable {
    private static let placeholder = "[redacted]"

    private let secrets: [String]
    private let checkInHosts: [String]

    /// - Parameter checkInURLs: the user's own check-in URLs; the path after each host is redacted.
    public init(secrets: [String], checkInURLs: [String] = []) {
        var variants: Set<String> = []
        for secret in secrets where !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variants.insert(secret)
            for allowed in Self.encodingSets {
                if let encoded = secret.addingPercentEncoding(withAllowedCharacters: allowed) {
                    variants.insert(encoded)
                }
            }
        }
        // Longest first; ties broken alphabetically so the result is deterministic.
        self.secrets = variants.sorted { ($0.count, $1) > ($1.count, $0) }

        var hosts: [String] = ["hc-ping.com"]
        for url in checkInURLs {
            if let host = URLComponents(string: url)?.host, !host.isEmpty { hosts.append(host.lowercased()) }
        }
        self.checkInHosts = Array(Set(hosts)).sorted()
    }

    /// Every encoder differs in what it leaves alone, so cover the common ones.
    private static let encodingSets: [CharacterSet] = {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return [unreserved, .urlUserAllowed, .urlPasswordAllowed, .urlQueryAllowed, .urlPathAllowed]
    }()

    public func redact(_ s: String) -> String {
        var out = s
        for secret in secrets { out = out.replacingOccurrences(of: secret, with: Self.placeholder) }
        out = Self.replace(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s@]+@"#, in: out, with: "$1\(Self.placeholder)@")
        for host in checkInHosts {
            let pattern = #"(https?://(?:[A-Za-z0-9\-]+\.)*"# + NSRegularExpression.escapedPattern(for: host)
                + #"(?::\d+)?)/\S*"#
            out = Self.replace(pattern, in: out, with: "$1/\(Self.placeholder)", caseInsensitive: true)
        }
        return out
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
