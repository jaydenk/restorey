import Foundation

/// The repository password setup suggests (UI design §4 step 3): six words from the EFF large word list,
/// joined by "-", each drawn uniformly with the system's secure generator. 6 × log2(7,776) ≈ 77.5 bits.
/// The list is vendored unchanged as `Resources/eff_large_wordlist.txt` (licence in the README).
///
/// A generated password is a secret like any other: the caller shows it to the user and hands it to the
/// agent, and never logs or saves it.
public enum PasswordGenerator {
    public static let wordCount = 6

    public static var entropyBits: Double { Double(wordCount) * log2(Double(words.count)) }

    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    /// `Int.random(in:using:)` draws without modulo bias.
    public static func make<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<wordCount).map { _ in words[Int.random(in: 0..<words.count, using: &generator)] }
            .joined(separator: "-")
    }

    /// The 7,776 words, in the list's order. The file's lines are `<five dice digits><tab><word>`.
    /// A list that is missing or isn't the expected one is a broken build, never a weaker password.
    static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "eff_large_wordlist", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("The EFF word list is missing from RestoreyCore's resources") }
        let words = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: "\t")
            return fields.count == 2 ? String(fields[1]) : nil
        }
        precondition(words.count == 7776 && Set(words).count == 7776, "The EFF word list isn't the 7,776-word list")
        return words
    }()
}
