import Foundation

/// What an item dragged in (or chosen in the open panel) is on disk. The app reads it (`URLResourceValues`); the rules
/// below decide.
public enum PickedItemKind: Sendable, Equatable {
    /// A folder or a drive's root: what the lists hold.
    case folder
    /// A file, or a package such as an app, which the open panel treats as a file (`treatsFilePackagesAsDirectories`
    /// is false) and so never offers here.
    case file
    /// Not a file at all: a web link.
    case notOnDisk
    /// A path with nothing there, a broken link included.
    case missing
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

extension PickedItem {
    /// What each URL is on disk, judged where it leads: a link to a folder is a folder (Finder and the open panel hand
    /// over the link, and before Task 17e the add button took it), a link to a file is a file, and a broken link is
    /// missing. The path kept is the one the person chose (standardised, not resolved), as the add button stored
    /// before; `FormValidation.addingSources` already compares sources by where they lead. A package such as an app is
    /// a file, as the open panel treats it (`treatsFilePackagesAsDirectories` is false). Reads only the file system's
    /// own facts (`fileExists(atPath:isDirectory:)`, which follows links, and `isPackageKey`), never a file's contents.
    public static func classify(_ urls: [URL], fileManager: FileManager = .default) -> [PickedItem] {
        urls.map { url in
            guard url.isFileURL else { return PickedItem(path: url.absoluteString, kind: .notOnDisk) }
            let path = url.standardizedFileURL.path
            let target = url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                return PickedItem(path: path, kind: .missing)
            }
            let isPackage = (try? target.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            return PickedItem(path: path, kind: isDirectory.boolValue && !isPackage ? .folder : .file)
        }
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
        /// Something worth knowing about what was added (not a problem): folders it replaced, or the plan's repository
        /// being left out of it. Nil when there is nothing to say.
        public var note: String?

        public init(list: [String], problem: String? = nil, note: String? = nil) {
            self.list = list
            self.problem = problem
            self.note = note
        }
    }

    /// Sources, as the agent stores them: absolute, standardised paths, deduplicated by the place they lead to
    /// (`FormValidation.addingSources`), so a symlink to a listed folder isn't added twice. Beyond that (Task 1):
    /// a folder inside one already listed is refused (it is already backed up), a folder holding listed ones replaces
    /// them (and says so), and, when the plan's repository is a local folder, that folder and anything inside it is
    /// refused, while a folder holding it is added with a note that the repository is left out (the backup always
    /// excludes it). `home` is only for naming the home folder in the sentences.
    public static func addingSources(
        _ items: [PickedItem], to sources: [String], repository: Repository?, home: String = NSHomeDirectory()
    ) -> Outcome {
        var list = sources
        var refused = Refused()
        var notes: [String] = []
        let repositoryPath = repository?.localFolderPath
        for item in items {
            guard refused.accepts(item) else { continue }
            let added = FormValidation.addingSources([item.path], to: list)
            guard added.count > list.count, let path = added.last else {
                refused.listed.append(name(item.path))
                continue
            }
            if let repositoryPath, SourcePaths.containsFollowingLinks(repositoryPath, path) {
                if SourcePaths.containsFollowingLinks(path, repositoryPath) {
                    refused.repositoryItself.append(name(path))
                } else {
                    refused.insideRepository.append(name(path))
                }
                continue
            }
            if let container = list.first(where: { SourcePaths.containsFollowingLinks($0, path) }) {
                refused.covered.append((name(path), container))
                continue
            }
            let replaced = list.filter { SourcePaths.containsFollowingLinks(path, $0) }
            list = list.filter { !replaced.contains($0) } + [path]
            if let note = replacementNote(for: path, replacing: replaced, home: home) { notes.append(note) }
            if let repositoryPath, SourcePaths.containsFollowingLinks(path, repositoryPath) {
                notes.append("This plan’s backups are kept inside “\(name(path))”, so that folder is always left out.")
            }
        }
        return Outcome(
            list: list, problem: refused.problem(home: home), note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func replacementNote(for parent: String, replacing replaced: [String], home: String) -> String? {
        guard !replaced.isEmpty else { return nil }
        let subject = displayName(parent, home: home, startingSentence: true)
        let names = replaced.map { "“\(name($0))”" }
        switch names.count {
        case 1: return "\(subject) includes \(names[0]), so it was taken off the list."
        case 2: return "\(subject) includes \(names[0]) and \(names[1]), so they were taken off the list."
        default: return "\(subject) includes \(names.count) folders that were in the list, so they were taken off it."
        }
    }

    /// A folder as a sentence names it: “Pictures”, or the home folder in words ("Your" at the start of a sentence).
    private static func displayName(_ path: String, home: String, startingSentence: Bool = false) -> String {
        if SourcePaths.containsFollowingLinks(path, home) && SourcePaths.containsFollowingLinks(home, path) {
            return startingSentence ? "Your home folder" : "your home folder"
        }
        return "“\(name(path))”"
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
        var missing: [String] = []
        var listed: [String] = []
        /// Folders already inside a listed folder: each with its own name and the listed folder that holds it.
        var covered: [(name: String, container: String)] = []
        var repositoryItself: [String] = []
        var insideRepository: [String] = []

        mutating func accepts(_ item: PickedItem) -> Bool {
            switch item.kind {
            case .folder: return true
            case .file: files.append(FolderDrop.name(item.path))
            case .notOnDisk: elsewhere += 1
            case .missing: missing.append(FolderDrop.name(item.path))
            }
            return false
        }

        /// One sentence per kind of refusal, naming the item when there is one.
        var problem: String? { problem(home: NSHomeDirectory()) }

        func problem(home: String) -> String? {
            var sentences: [String] = []
            switch files.count {
            case 0: break
            case 1: sentences.append("“\(files[0])” isn’t a folder. Only folders and drives can be added.")
            default: sentences.append("\(files.count) items aren’t folders. Only folders and drives can be added.")
            }
            if elsewhere > 0 { sentences.append("Only folders and drives on this Mac can be added.") }
            switch missing.count {
            case 0: break
            case 1: sentences.append("“\(missing[0])” can’t be found.")
            default: sentences.append("\(missing.count) items can’t be found.")
            }
            switch listed.count {
            case 0: break
            case 1: sentences.append("“\(listed[0])” is already in the list.")
            default: sentences.append("\(listed.count) folders are already in the list.")
            }
            switch covered.count {
            case 0: break
            case 1:
                sentences.append(
                    "“\(covered[0].name)” is already included in \(FolderDrop.displayName(covered[0].container, home: home)).")
            default: sentences.append("\(covered.count) folders are already included in folders in the list.")
            }
            switch repositoryItself.count {
            case 0: break
            case 1:
                sentences.append("“\(repositoryItself[0])” is where this plan’s backups are kept, so it can’t be backed up.")
            default:
                sentences.append("\(repositoryItself.count) folders are where this plan’s backups are kept, so they can’t be backed up.")
            }
            switch insideRepository.count {
            case 0: break
            case 1:
                sentences.append(
                    "“\(insideRepository[0])” is inside the folder where this plan’s backups are kept, so it can’t be backed up.")
            default:
                sentences.append(
                    "\(insideRepository.count) folders are inside the folder where this plan’s backups are kept, so they can’t be backed up.")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// The name Finder shows for a path: its last component, or "/" for the startup disk's root.
    /// Pure string handling (`SourcePaths.lastComponent`): the agent names folders with this when it builds a status.
    public static func name(_ path: String) -> String {
        SourcePaths.lastComponent(path)
    }
}
