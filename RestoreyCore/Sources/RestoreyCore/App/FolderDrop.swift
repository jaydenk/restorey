import Foundation

/// What an item dragged in (or chosen in the open panel) is on disk. The app reads it (`URLResourceValues`); the rules
/// below decide.
public enum PickedItemKind: Sendable, Equatable {
    /// A folder or a drive's root: what the lists hold.
    case folder
    /// A file, or a package such as an app, which the open panel treats as a file (`treatsFilePackagesAsDirectories`
    /// is false) and so never offers here.
    case file
    /// Not a file on this Mac: a web link, or a file that has gone.
    case notOnDisk
}

/// An item to add to a plan's Folders list or Exclusions list.
public struct PickedItem: Sendable, Equatable {
    public var path: String
    public var kind: PickedItemKind

    public init(path: String, kind: PickedItemKind) {
        self.path = path
        self.kind = kind
    }
}

/// The one rule for adding to a plan's Folders list and its Exclusions list (Task 17e, audit T3), whether the items come
/// from the open panel ("Add Folder or Drive…", "Add Folder…") or are dragged in from Finder: only folders and drives,
/// and nothing already listed. It reports what it left out, so a drop that adds nothing still says why.
public enum FolderDrop {
    public struct Outcome: Sendable, Equatable {
        /// The list with the new items added at the end, in the order they came.
        public var list: [String]
        /// Why some items weren't added: nil when every item was.
        public var problem: String?
    }

    /// Sources, as the agent stores them: absolute, standardised paths, deduplicated by the place they lead to
    /// (`FormValidation.addingSources`), so a symlink to a listed folder isn't added twice.
    public static func addingSources(_ items: [PickedItem], to sources: [String]) -> Outcome {
        var list = sources
        var refused = Refused()
        for item in items {
            guard refused.accepts(item) else { continue }
            let added = FormValidation.addingSources([item.path], to: list)
            if added.count == list.count { refused.listed.append(name(item.path)) } else { list = added }
        }
        return Outcome(list: list, problem: refused.problem)
    }

    /// Folders left out, as exclusion patterns (`DefaultExclusions.pattern(forFolder:)`); Restorey's own folders are
    /// always listed, so dropping one of them is a duplicate.
    public static func addingExclusions(_ items: [PickedItem], to exclusions: [String]) -> Outcome {
        var list = exclusions
        var refused = Refused()
        for item in items {
            guard refused.accepts(item) else { continue }
            let pattern = DefaultExclusions.pattern(forFolder: item.path)
            if list.contains(pattern) { refused.listed.append(name(item.path)) } else { list.append(pattern) }
        }
        return Outcome(list: list, problem: refused.problem)
    }

    private struct Refused {
        var files: [String] = []
        var elsewhere = 0
        var listed: [String] = []

        mutating func accepts(_ item: PickedItem) -> Bool {
            switch item.kind {
            case .folder: return true
            case .file: files.append(FolderDrop.name(item.path))
            case .notOnDisk: elsewhere += 1
            }
            return false
        }

        /// One sentence per kind of refusal, naming the item when there is one.
        var problem: String? {
            var sentences: [String] = []
            switch files.count {
            case 0: break
            case 1: sentences.append("“\(files[0])” isn’t a folder. Only folders and drives can be added.")
            default: sentences.append("\(files.count) items aren’t folders. Only folders and drives can be added.")
            }
            if elsewhere > 0 { sentences.append("Only folders and drives on this Mac can be added.") }
            switch listed.count {
            case 0: break
            case 1: sentences.append("“\(listed[0])” is already in the list.")
            default: sentences.append("\(listed.count) folders are already in the list.")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// The name Finder shows for a path: its last component, or "/" for the startup disk's root.
    static func name(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }
}
