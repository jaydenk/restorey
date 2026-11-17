import Foundation

/// Reads a `verbose_status` line laid out exactly as restic 0.19.1 writes it (`VerboseItem`), without the JSON
/// decoder: a backup of a home folder prints millions of them, and the decoder costs microseconds each (Task 16d).
/// Only the fields the biggest additions need are read; the rest of the line is checked only for its closing brace,
/// so a line cut short is never read as a smaller size.
enum VerboseLineReader {
    enum Result: Equatable {
        case item(VerboseItem)
        /// In restic's layout but unreadable (cut short, a bad escape, a size that isn't a whole number of bytes).
        case malformed
        /// Not in restic 0.19.1's layout (another field order, spaces): the decoder reads it instead.
        case otherLayout
    }

    private static let action = Array(#"{"message_type":"verbose_status","action":""#.utf8)
    private static let item = Array(#"","item":""#.utf8)
    private static let duration = Array(#","duration":"#.utf8)
    private static let dataSize = Array(#","data_size":"#.utf8)
    private static let dataSizeInRepo = Array(#","data_size_in_repo":"#.utf8)

    static func read(_ line: String) -> Result {
        var line = line
        return line.withUTF8 { read(bytes: $0) }
    }

    private static func read(bytes: UnsafeBufferPointer<UInt8>) -> Result {
        var reader = Reader(bytes: bytes)
        guard bytes.last == UInt8(ascii: "}") else { return .malformed }
        guard reader.expect(action) else { return reader.layoutOrCut }
        // An action is a plain word: one with an escape isn't restic's.
        guard let actionEnd = reader.find(UInt8(ascii: "\"")) else { return .malformed }
        let actionBytes = UnsafeBufferPointer(rebasing: bytes[reader.index..<actionEnd])
        guard !actionBytes.contains(UInt8(ascii: "\\")) else { return .otherLayout }
        reader.index = actionEnd
        guard reader.expect(item) else { return reader.layoutOrCut }
        guard let path = reader.string() else { return .malformed }
        guard reader.expect(duration) else { return reader.layoutOrCut }
        guard reader.skipNumber() else { return .malformed }
        guard reader.expect(dataSize) else { return reader.layoutOrCut }
        guard reader.unsigned() != nil else { return .malformed }
        guard reader.expect(dataSizeInRepo) else { return reader.layoutOrCut }
        guard let size = reader.unsigned(), let next = reader.peek,
            next == UInt8(ascii: ",") || next == UInt8(ascii: "}")
        else { return .malformed }
        return .item(VerboseItem(
            action: String(decoding: actionBytes, as: UTF8.self), item: path, dataSizeInRepo: size))
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        /// A literal that didn't match: restic's layout cut short when the line ran out first, otherwise another layout.
        var layoutOrCut: Result { index >= bytes.count ? .malformed : .otherLayout }

        /// Consumes `literal` if the bytes here start with it. On a mismatch, `index` is left at the end of the line
        /// when the line ran out (so `layoutOrCut` says "cut short"), otherwise where it was.
        mutating func expect(_ literal: [UInt8]) -> Bool {
            let end = index + literal.count
            guard end <= bytes.count else {
                let available = bytes.count - index
                if available >= 0, bytes[index...].elementsEqual(literal.prefix(available)) { index = bytes.count }
                return false
            }
            guard bytes[index..<end].elementsEqual(literal) else { return false }
            index = end
            return true
        }

        func find(_ byte: UInt8) -> Int? {
            var i = index
            while i < bytes.count {
                if bytes[i] == byte { return i }
                i += 1
            }
            return nil
        }

        /// A JSON string's contents up to its closing quote, escapes undone; the quote is consumed.
        mutating func string() -> String? {
            let start = index
            // Most names have no escape: one pass to the closing quote, then one copy.
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    defer { index += 1 }
                    return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") { break }
                index += 1
            }
            guard index < bytes.count else { return nil }
            var out = Array(bytes[start..<index])
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let escaped = peek else { return nil }
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let scalar = unicodeEscape() else { return nil }
                        out.append(contentsOf: String(Character(scalar)).utf8)
                    default: return nil
                    }
                default:
                    out.append(byte)
                }
            }
            return nil
        }

        /// The scalar of a `\uXXXX` escape (the `\u` already consumed), joining a surrogate pair. Nil for a lone surrogate.
        private mutating func unicodeEscape() -> Unicode.Scalar? {
            guard let high = hex4() else { return nil }
            switch high {
            case 0xD800...0xDBFF:
                guard expect(Array(#"\u"#.utf8)), let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
            case 0xDC00...0xDFFF:
                return nil
            default:
                return Unicode.Scalar(high)
            }
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: return nil
                }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }

        /// Skips a JSON number (the duration, a float), up to the next field.
        mutating func skipNumber() -> Bool {
            let start = index
            while let byte = peek, byte != UInt8(ascii: ","), byte != UInt8(ascii: "}") { index += 1 }
            return index > start && index < bytes.count
        }

        /// A whole number of bytes. Nil for none, a sign, a fraction or one too big for `Int64`.
        mutating func unsigned() -> Int64? {
            let start = index
            var value: Int64 = 0
            while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                let (times, overflow1) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = times.addingReportingOverflow(Int64(byte - UInt8(ascii: "0")))
                guard !overflow1, !overflow2 else { return nil }
                value = sum
                index += 1
            }
            return index > start ? value : nil
        }
    }
}
