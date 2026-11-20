import Foundation
import Testing

/// Final review round 2, widened in round 3: nothing the agent runs to build a status, schedule a run or name a folder
/// in an alert may read the disk, since a repository on a network volume that stops answering would stall the agent
/// with it. A stat can't be observed from a test without such a volume, so this pins the source instead: every `.swift`
/// file in the directories below (not a hand-kept list, so a new file is covered the day it is added) is scanned for
/// the calls that touch the disk, outside comments:
///
/// - `URL(fileURLWithPath:)` / `.init(fileURLWithPath:)` without `isDirectory:` (that form stats the path to learn
///   whether it is a folder), whether the call is on one line or wrapped across several;
/// - `appendingPathComponent(` without `isDirectory:` (the same stat);
/// - `standardizingPath`, `standardizedFileURL` and `resolvingSymlinksInPath` (they follow links);
/// - `fileExists`, `resourceValues` and `attributesOfItem`.
///
/// Where a file legitimately needs the disk it is in `allowed`, with the reason.
struct StatusPathPurityTests {
    private static let sources = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)

    /// The directories scanned, every file in them: all of the agent's, and the shared code that builds a status, a
    /// schedule, an alert or a restic invocation.
    private static let directories = [
        "AgentCore", "RestoreyCore/Config", "RestoreyCore/Schedule", "RestoreyCore/Alerts", "RestoreyCore/Restic",
    ]

    /// `RestoreyCore/App` is the app's own code, much of which reads the disk on purpose (`AppMove`, `PrivateFile`, the
    /// form checks, opening a run log), so it is scanned by name: the files whose text reaches a status, a menu or an
    /// alert, which the agent's code also uses.
    private static let appFiles = [
        "RestoreyCore/App/MenuPresentation.swift", "RestoreyCore/App/PlanNote.swift", "RestoreyCore/App/FolderDrop.swift",
    ]

    static let files: [String] = appFiles + directories.flatMap { directory -> [String] in
        let root = sources.appendingPathComponent(directory, isDirectory: true)
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return found.filter { $0.pathExtension == "swift" }.map { url in
            "\(directory)/" + url.path.dropFirst(root.path.count + 1)
        }.sorted()
    }

    /// Where the disk is read on purpose: the file, and for each the text of the call (or line) that may, with why.
    /// The match is on the text of the call or line, never a line number, so it survives edits above it.
    private static let allowed: [String: [String]] = [
        // `SourcePaths.resolvingLinks` is where links are followed. Only `LinkResolver` calls it on the agent's side, on a
        // thread of its own with a deadline and one check outstanding.
        "RestoreyCore/Config/SourcePaths.swift": ["URL(fileURLWithPath: standardised(path), isDirectory: true).resolvingSymlinksInPath()"],
        // `FolderDrop.classify` runs in the app, on a drop, to learn what was dropped; the agent never calls it.
        "RestoreyCore/App/FolderDrop.swift": [
            "let path = url.standardizedFileURL.path", "let target = url.resolvingSymlinksInPath()",
            "fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)",
            "target.resourceValues(forKeys: [.isPackageKey])",
        ],
        // The probe's whole job is to look at the protected folders under home; it runs on its own thread, bounded.
        "AgentCore/FullDiskAccessProbe.swift": ["fm.fileExists(atPath: path, isDirectory: &isDirectory)"],
        // The config and state files: reading and writing them is the store's job, serialised on the agent's write
        // queue, and never part of building a status (which reads memory).
        "RestoreyCore/Config/VersionedStore.swift": [
            "FileManager.default.attributesOfItem(atPath: backup.path)", "FileManager.default.fileExists(atPath: fileURL.path)",
        ],
        // The cloud-only count walks the sources on a thread of its own, under a deadline and one walk at a time.
        "RestoreyCore/Restic/CloudOnlyCount.swift": ["(path as NSString).standardizingPath"],
        // Checking that a marked item still exists, in the Spotlight finder that only ever runs through `OwnThread`
        // with a deadline and `OneOutstandingGate.spotlight`.
        "RestoreyCore/Restic/SpotlightMarkedItems.swift": ["FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)"],
        // `fileExists` here is the injected check (a closure, so the decision stays pure and tests never touch the disk),
        // not a call to the file system.
        "RestoreyCore/Schedule/Preflight.swift": ["fileExists"],
    ]

    @Test func scansEveryFileInTheDirectories() {
        #expect(Self.files.contains("AgentCore/PlanRunner.swift"))
        #expect(Self.files.contains("RestoreyCore/Config/SourcePaths.swift"))
        #expect(Self.files.contains("RestoreyCore/Restic/DefaultExclusions.swift"))
        #expect(Self.files.contains("RestoreyCore/App/FolderDrop.swift"))
        #expect(Self.files.count > 30, "the directories were found")
        for (file, _) in Self.allowed { #expect(Self.files.contains(file), "\(file) is allowlisted but not scanned") }
    }

    @Test(arguments: files)
    func readsNothingFromTheDisk(file: String) throws {
        let raw = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
        let text = Self.withoutComments(raw)
        for hit in Self.hits(in: text) {
            if Self.allowed[file, default: []].contains(where: hit.text.contains) { continue }
            Issue.record("\(file):\(hit.line) \(hit.reason): \(hit.text)")
        }
    }

    /// The scan finds what it should: a call wrapped across lines, `.init`, and no hit inside a comment.
    @Test func theScanFindsEachPatternAndIgnoresComments() {
        func reasons(_ code: String) -> [String] { Self.hits(in: Self.withoutComments(code)).map(\.reason) }
        let stat = "URL(fileURLWithPath:) without isDirectory:"
        #expect(reasons("let u = URL(fileURLWithPath: p)") == [stat])
        #expect(reasons("let u: URL = .init(fileURLWithPath: p)") == [stat])
        #expect(reasons("let u = URL(\n    fileURLWithPath: p,\n    relativeTo: base)") == [stat])
        #expect(reasons("let u = URL(fileURLWithPath: p,\n    isDirectory: true)").isEmpty)
        #expect(reasons("a.appendingPathComponent(name)") == ["appendingPathComponent( without isDirectory:"])
        #expect(reasons("a.appendingPathComponent(name,\n isDirectory: false)").isEmpty)
        #expect(reasons("(p as NSString).standardizingPath") == ["standardizingPath"])
        #expect(reasons("fm.fileExists(atPath: p)") == ["fileExists"])
        #expect(reasons("try u.resourceValues(forKeys: [])") == ["resourceValues"])
        #expect(reasons("try fm.attributesOfItem(atPath: p)") == ["attributesOfItem"])
        #expect(reasons("// URL(fileURLWithPath: p) fileExists\nlet x = 1 // standardizingPath").isEmpty)
        #expect(reasons("/* URL(fileURLWithPath: p)\n fileExists */ let x = 1").isEmpty)
    }

    struct Hit {
        let line: Int
        let reason: String
        /// The whole call for the two argument-checked forms, else the line the word is on.
        let text: String
    }

    /// `code` with comments blanked (newlines kept, so line numbers hold). String literals are not parsed: a `//` inside
    /// one blanks the rest of its line, which can only hide a hit after it, never invent one.
    static func withoutComments(_ code: String) -> String {
        var result = ""
        var chars = code[...]
        var inBlock = false
        var inLine = false
        while let c = chars.first {
            let next = chars.dropFirst().first
            if inBlock {
                if c == "*", next == "/" { inBlock = false; chars = chars.dropFirst(2); continue }
                result.append(c == "\n" ? "\n" : " ")
            } else if inLine {
                if c == "\n" { inLine = false; result.append("\n") } else { result.append(" ") }
            } else if c == "/", next == "*" {
                inBlock = true; result += "  "; chars = chars.dropFirst(2); continue
            } else if c == "/", next == "/" {
                inLine = true; result += "  "; chars = chars.dropFirst(2); continue
            } else {
                result.append(c)
            }
            chars = chars.dropFirst()
        }
        return result
    }

    static func hits(in text: String) -> [Hit] {
        var found: [Hit] = []
        func line(at index: String.Index) -> Int { text[..<index].filter { $0 == "\n" }.count + 1 }

        /// From the `(` that opens the call to its matching `)`, joined across lines.
        func call(from start: String.Index) -> String {
            var depth = 0
            var end = start
            for index in text[start...].indices {
                end = index
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1; if depth == 0 { break } }
            }
            return String(text[start...end])
        }

        /// `marker` followed by an argument list (`name(` or `name:` inside one) must carry `isDirectory:`.
        func scanCalls(_ marker: String, opensCall: Bool, reason: String) {
            var from = text.startIndex
            while let range = text.range(of: marker, range: from..<text.endIndex) {
                from = range.upperBound
                let open = opensCall
                    ? text.index(before: range.upperBound)
                    : text[..<range.lowerBound].lastIndex(of: "(") ?? range.lowerBound
                let whole = call(from: open)
                if whole.contains("isDirectory:") { continue }
                found.append(Hit(line: line(at: range.lowerBound), reason: reason, text: whole))
            }
        }

        func scanWord(_ word: String) {
            var from = text.startIndex
            while let range = text.range(of: word, range: from..<text.endIndex) {
                from = range.upperBound
                let start = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let end = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                let whole = text[start..<end].trimmingCharacters(in: .whitespaces)
                found.append(Hit(line: line(at: range.lowerBound), reason: word, text: whole))
            }
        }

        scanCalls("fileURLWithPath:", opensCall: false, reason: "URL(fileURLWithPath:) without isDirectory:")
        scanCalls("appendingPathComponent(", opensCall: true, reason: "appendingPathComponent( without isDirectory:")
        for word in ["standardizingPath", "standardizedFileURL", "resolvingSymlinksInPath", "fileExists", "resourceValues", "attributesOfItem"] {
            scanWord(word)
        }
        return found
    }
}
