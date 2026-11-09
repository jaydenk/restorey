import Foundation

/// Throwaway spike. See docs/spike-findings.md.
enum SpikeIDs {
    static let appBundleID = "com.jaydenkerr.restorey.spike"
    static let agentLabel = "com.jaydenkerr.restorey.spike.agent"
    static let agentPlistName = "com.jaydenkerr.restorey.spike.agent.plist"
    static let keychainService = "com.jaydenkerr.restorey.spike"
    static let keychainAccount = "spike-repo"

    static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.jaydenkerr.restorey.spike", isDirectory: true)
    }
}

/// Every call takes a JSON request ({"command": …, …}) and replies with JSON,
/// so probes can add fields without changing the XPC interface.
@objc protocol AgentXPC {
    func perform(_ requestJSON: String, withReply reply: @escaping @Sendable (String) -> Void)
}

enum JSON {
    static func encode(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"error":"unencodable reply"}"# }
        return text
    }

    static func decode(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

enum Timestamp {
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
