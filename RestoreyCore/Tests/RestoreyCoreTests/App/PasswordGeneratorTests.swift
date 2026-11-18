import Foundation
import Testing

@testable import RestoreyCore

@Suite struct PasswordGeneratorTests {
    /// Always returns the same value, so each word drawn is the one at a known index. `Int.random(in:using:)`
    /// takes the high 64 bits of value × 7,776, retrying when the low bits fall under a small threshold, so a
    /// value just under 2^64 / 7,776 gives index 0 at once (0 itself would be retried for ever).
    private struct FixedGenerator: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { value }
    }

    @Test func theWordListIsEFFsLargeList() {
        let words = PasswordGenerator.words
        #expect(words.count == 7776)
        #expect(Set(words).count == 7776)
        #expect(words.first == "abacus")
        #expect(words.last == "zoom")
        #expect(words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLowercase || $0 == "-" } })
    }

    @Test func makesSixWordsFromTheListJoinedByHyphens() {
        var generator = FixedGenerator(value: UInt64.max / 7776)
        let password = PasswordGenerator.make(using: &generator)
        let word = PasswordGenerator.words[0]
        #expect(password == Array(repeating: word, count: 6).joined(separator: "-"))
        // The largest value gives the last word, so every index can be drawn.
        var last = FixedGenerator(value: UInt64.max)
        #expect(PasswordGenerator.make(using: &last) == Array(repeating: "zoom", count: 6).joined(separator: "-"))
    }

    @Test func eachPasswordSplitsIntoSixListWords() {
        // A few EFF words have a hyphen of their own ("t-shirt"), so a plain split by "-" isn't enough.
        for _ in 0..<200 {
            let password = PasswordGenerator.make()
            #expect(Self.wordCount(password) == 6, "\(password)")
        }
    }

    @Test func aThousandPasswordsAreAllDifferent() {
        let passwords = (0..<1000).map { _ in PasswordGenerator.make() }
        #expect(Set(passwords).count == 1000)
    }

    @Test func hasAboutSeventySevenBitsOfEntropy() {
        #expect(abs(PasswordGenerator.entropyBits - 77.5) < 0.1)
    }

    /// The number of list words `password` is made of, if it can be read as hyphen-joined list words.
    private static func wordCount(_ password: String) -> Int? {
        let parts = password.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let list = Set(PasswordGenerator.words)
        // counts[i]: the possible word counts for parts[i...].
        var counts: [Set<Int>] = Array(repeating: [], count: parts.count + 1)
        counts[parts.count] = [0]
        for start in stride(from: parts.count - 1, through: 0, by: -1) {
            for end in (start + 1)...parts.count where list.contains(parts[start..<end].joined(separator: "-")) {
                counts[start].formUnion(counts[end].map { $0 + 1 })
            }
        }
        return counts[0].count == 1 ? counts[0].first : (counts[0].contains(6) ? 6 : nil)
    }
}
