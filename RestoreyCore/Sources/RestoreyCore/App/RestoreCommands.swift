import Foundation

/// The restic commands that restore a plan's backups without Restorey (UI design §5 "Restore Files…", §7 the
/// recovery kit's "restore without Restorey"; the README's section of that name gives the same three). Pasted
/// into Terminal in order, with restic installed, they open the plan's repository and restore this Mac's latest
/// snapshot into `~/Restored`.
///
/// Each command has a masked `text`, where every secret is `mask`, and a `revealedText` with the real values,
/// each single-quoted so `sh` reads it byte for byte (spaces, quote marks, non-ASCII letters, newlines). Only
/// the first command carries secrets; the other two are the same either way.
public enum RestoreCommands {
    public struct Command: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        public var title: String
        /// Secrets shown as `mask`: safe to show on screen.
        public var text: String
        /// The command with every secret in it. Held only while the window or kit showing it is open.
        public var revealedText: String

        public init(title: String, text: String, revealedText: String) {
            self.title = title
            self.text = text
            self.revealedText = revealedText
        }

        public var id: String { title }
        /// Whether `revealedText` holds anything `text` doesn't show.
        public var hasSecrets: Bool { text != revealedText }

        // Never the revealed text, so a command can be logged or dumped safely.
        public var description: String { "Command(\(title): \(text))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror {
            Mirror(self, children: ["title": title, "text": text], displayStyle: .struct)
        }
    }

    /// What a secret looks like until it is revealed.
    public static let mask = "••••••••"

    /// The folder in the home folder the restore goes to. Left unquoted in the command so the shell expands `~`.
    public static let target = "~/Restored"

    /// The commands for `plan`. `secrets` are the plan's (the recovery kit's reply). A secret the plan needs that
    /// isn't among them stays `mask` in `revealedText` too: it can't be revealed, and an empty value would be a
    /// command that looks right and fails.
    public static func make(plan: Plan, secrets: [SecretEntry]) -> [Command] {
        let values = Dictionary(secrets.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var masked = ["export RESTIC_REPOSITORY=\(displayQuoted(plan.repository.resticRepository))"]
        var revealed = masked
        for (name, key) in variables(plan) {
            masked.append("export \(name)=\(mask)")
            guard let value = values[key] else {
                revealed.append("export \(name)=\(mask)")
                continue
            }
            let restic = key == .repositoryPassword(plan.id) ? resticPassword(value) : value
            revealed.append("export \(name)=\(shellQuoted(restic))")
        }
        let host = displayQuoted(plan.hostLabel)
        let snapshots = "restic snapshots --host \(host)"
        let restore = "restic restore latest --host \(host) --target \(target)"
        return [
            Command(
                title: "Tell restic where the repository is", text: masked.joined(separator: "\n"),
                revealedText: revealed.joined(separator: "\n")),
            Command(title: "List this Mac's snapshots", text: snapshots, revealedText: snapshots),
            Command(title: "Restore the latest snapshot to Restored in your home folder", text: restore, revealedText: restore),
        ]
    }

    /// The environment variables restic reads the plan's secrets from, in the recovery kit's order: the
    /// password, then an S3 plan's two keys (B2 through its S3 endpoint too) or a raw plan's own variables.
    static func variables(_ plan: Plan) -> [(name: String, key: SecretKey)] {
        var variables: [(name: String, key: SecretKey)] = [("RESTIC_PASSWORD", .repositoryPassword(plan.id))]
        switch plan.repository {
        case .s3:
            variables.append(("AWS_ACCESS_KEY_ID", .s3AccessKeyID(plan.id)))
            variables.append(("AWS_SECRET_ACCESS_KEY", .s3SecretAccessKey(plan.id)))
        case .raw(_, let names):
            variables += names.map { ($0, .environment(plan.id, name: $0)) }
        }
        return variables
    }

    /// The repository's password as restic knows it. The agent gives restic the stored password through
    /// `RESTIC_PASSWORD_COMMAND`, and restic trims what that command prints (Go's `strings.TrimSpace`), so a
    /// password stored with surrounding white space made, and opens, a repository whose password is without it.
    /// `RESTIC_PASSWORD` is read as it is, so the kit and the commands give this form. Checked against restic
    /// 0.19.1: a repository made with a command printing " pw \n" opens with `RESTIC_PASSWORD=pw` and refuses
    /// " pw \n" (exit 12); `RestoreCommandsTests` repeats it end to end. Trimmed by Unicode scalar, as Go trims
    /// by rune, by the Unicode White_Space property, which is what Go's `unicode.IsSpace` tests.
    public static func resticPassword(_ stored: String) -> String {
        let scalars = stored.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })!
        return String(String.UnicodeScalarView(scalars[first...last]))
    }
}
