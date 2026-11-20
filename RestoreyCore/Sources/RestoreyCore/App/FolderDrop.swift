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
    /// before; `FolderDrop.addingSources` compares sources by where they lead. A package such as an app is a file, as
    /// the open panel treats it (`treatsFilePackagesAsDirectories` is false). Reads only the file system's own facts
    /// (`follow`, `fileExists(atPath:isDirectory:)` and `isPackageKey`), never a file's contents, and can block for as
    /// long as a volume doesn't answer: it runs only inside `FolderDrop.look`, on the link check's thread.
    static func classify(
        _ urls: [URL], follow: (String) -> String, fileManager: FileManager = .default
    ) -> [(item: PickedItem, leadsTo: String?)] {
        urls.map { url in
            guard url.isFileURL else { return (PickedItem(path: url.absoluteString, kind: .notOnDisk), nil) }
            let path = SourcePaths.standardised(url.path)
            let target = follow(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target, isDirectory: &isDirectory) else {
                return (PickedItem(path: path, kind: .missing), nil)
            }
            let found = URL(fileURLWithPath: target, isDirectory: isDirectory.boolValue)
            let isPackage = (try? found.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            return (PickedItem(path: path, kind: isDirectory.boolValue && !isPackage ? .folder : .file), target)
        }
    }

    /// Each URL judged by its path as written, reading nothing: a file URL written as a folder (`hasDirectoryPath`, a
    /// trailing slash, string handling only) is taken as the folder chosen; any other file URL is refused as not a
    /// folder, so a file or an app is never added in its place (a link to a folder, written without the slash, is
    /// refused too, and can be added again once the disk answers); anything else isn't on this Mac. The answer when
    /// the disk didn't answer in time.
    static func byPath(_ urls: [URL]) -> [PickedItem] {
        urls.map { url in
            guard url.isFileURL else { return PickedItem(path: url.absoluteString, kind: .notOnDisk) }
            return PickedItem(path: SourcePaths.standardised(url.path), kind: url.hasDirectoryPath ? .folder : .file)
        }
    }
}

/// The one rule for adding to a plan's Folders list and its Exclusions list (Task 17e, audit T3), whether the items come
/// from the open panel ("Add Folder or Drive…", "Add Folder…") or are dragged in from Finder: only folders and drives,
/// and nothing already listed. It reports what it left out, so a drop that adds nothing still says why.
///
/// Two steps, so the app's main actor never waits on a volume that stops answering (L157): `look` reads the disk (what
/// each item is, and where it and the paths it is compared with lead) through `LinkResolver`, on a thread of its own
/// with its 10 s deadline and one look outstanding in the process; `addingSources` and `addingExclusions` then apply
/// the rule to what it found, by string handling alone, against the lists as they are when it returns.
public enum FolderDrop {
    /// What `look` read from the disk.
    public struct Look: Sendable, Equatable {
        /// Each item, in the order given.
        public var items: [PickedItem]
        /// Where each folder among `items`, and each path it was asked to compare them with, leads once links are
        /// followed, keyed by its standardised path. Empty when the disk wasn't checked in time.
        public var leads: [String: String]
        /// False when the disk didn't answer within the deadline, or an earlier look is still stuck past its own: every
        /// item is then judged by its path as written (`PickedItem.byPath`) and compared by path, and adding says so
        /// (`uncheckedNote`).
        public var checkedInTime: Bool

        public init(items: [PickedItem], leads: [String: String], checkedInTime: Bool = true) {
            self.items = items
            self.leads = leads
            self.checkedInTime = checkedInTime
        }
    }

    /// Said under the list when an add was judged by the paths as written because the disk wasn't checked in time.
    public static let uncheckedNote = "Restorey couldn’t check these in time, so they were added as chosen."

    /// What each of `urls` is, and where the folders among them and `paths` lead (for sources: the list, the plan's
    /// local repository folder and the home folder), read on `resolver`'s thread within its deadline. Past the
    /// deadline, or while an earlier look is stuck past its own, each item is judged by its path as written.
    public static func look(
        at urls: [URL], against paths: [String] = [], resolver: LinkResolver = .live
    ) async -> Look {
        let others = paths.map(SourcePaths.standardised)
        let found = await resolver.look { follow in
            let read = PickedItem.classify(urls, follow: follow)
            var leads: [String: String] = [:]
            for (item, target) in read { if item.kind == .folder, let target { leads[item.path] = target } }
            for path in others where leads[path] == nil { leads[path] = follow(path) }
            return Look(items: read.map(\.item), leads: leads)
        }
        return found ?? Look(items: PickedItem.byPath(urls), leads: [:], checkedInTime: false)
    }

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

    /// `addingSources` with what `look` found, and `uncheckedNote` after any other note when it wasn't checked in time
    /// and something was added.
    public static func addingSources(
        _ look: Look, to sources: [String], repository: Repository?, home: String = NSHomeDirectory()
    ) -> Outcome {
        unchecked(look, addingSources(look.items, to: sources, repository: repository, home: home, leads: look.leads), sources)
    }

    /// `addingExclusions` with what `look` found, and `uncheckedNote` when it wasn't checked in time and something was
    /// added.
    public static func addingExclusions(_ look: Look, to exclusions: [String]) -> Outcome {
        unchecked(look, addingExclusions(look.items, to: exclusions), exclusions)
    }

    private static func unchecked(_ look: Look, _ outcome: Outcome, _ before: [String]) -> Outcome {
        guard !look.checkedInTime, outcome.list != before else { return outcome }
        var outcome = outcome
        outcome.note = [outcome.note, uncheckedNote].compactMap { $0 }.joined(separator: " ")
        return outcome
    }

    /// Sources, as the agent stores them: absolute, standardised paths, deduplicated by the place they lead to
    /// (`leads`, from `look`), so a symlink to a listed folder isn't added twice. Beyond that (Task 1): a folder inside
    /// one already listed is refused (it is already backed up), a folder holding listed ones replaces them (and says
    /// so), and, when the plan's repository is a local folder, that folder and anything inside it is refused, while a
    /// folder holding it is added with a note that the repository is left out (the backup always excludes it). Each
    /// comparison is by path (`SourcePaths.containsByPath`) and, for paths in `leads`, by where they lead; it never
    /// reads the disk. `home` is only for naming the home folder in the sentences.
    public static func addingSources(
        _ items: [PickedItem], to sources: [String], repository: Repository?, home: String = NSHomeDirectory(),
        leads: [String: String] = [:]
    ) -> Outcome {
        let places = Places(leads: leads)
        var list = sources
        var refused = Refused()
        var notes: [String] = []
        let repositoryPath = repository?.localFolderPath
        for item in items {
            guard refused.accepts(item) else { continue }
            let path = SourcePaths.standardised(item.path)
            guard !list.contains(where: { places.same($0, path) }) else {
                refused.listed.append(name(item.path))
                continue
            }
            if let repositoryPath, places.contains(repositoryPath, path) {
                if places.contains(path, repositoryPath) {
                    refused.repositoryItself.append(name(path))
                } else {
                    refused.insideRepository.append(name(path))
                }
                continue
            }
            if let container = list.first(where: { places.contains($0, path) }) {
                refused.covered.append((name(path), container))
                continue
            }
            let replaced = list.filter { places.contains(path, $0) }
            list = list.filter { !replaced.contains($0) } + [path]
            if let note = replacementNote(for: path, replacing: replaced, home: home, places: places) { notes.append(note) }
            if let repositoryPath, places.contains(path, repositoryPath) {
                notes.append("This plan’s backups are kept inside “\(name(path))”, so that folder is always left out.")
            }
        }
        return Outcome(
            list: list, problem: refused.problem(home: home, places: places),
            note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Paths compared as written and, where `leads` knows them, as where they lead. Pure.
    private struct Places {
        let leads: [String: String]

        func leadsTo(_ path: String) -> String { leads[SourcePaths.standardised(path)] ?? path }

        func contains(_ outer: String, _ inner: String) -> Bool {
            SourcePaths.containsByPath(outer, inner) || SourcePaths.containsByPath(leadsTo(outer), leadsTo(inner))
        }

        func same(_ a: String, _ b: String) -> Bool {
            SourcePaths.sameFirmlinkSpelling(a, b) || SourcePaths.sameFirmlinkSpelling(leadsTo(a), leadsTo(b))
        }
    }

    private static func replacementNote(
        for parent: String, replacing replaced: [String], home: String, places: Places
    ) -> String? {
        guard !replaced.isEmpty else { return nil }
        let subject = displayName(parent, home: home, places: places, startingSentence: true)
        let names = replaced.map { "“\(name($0))”" }
        switch names.count {
        case 1: return "\(subject) includes \(names[0]), so it was taken off the list."
        case 2: return "\(subject) includes \(names[0]) and \(names[1]), so they were taken off the list."
        default: return "\(subject) includes \(names.count) folders that were in the list, so they were taken off it."
        }
    }

    /// A folder as a sentence names it: “Pictures”, or the home folder in words ("Your" at the start of a sentence).
    private static func displayName(
        _ path: String, home: String, places: Places, startingSentence: Bool = false
    ) -> String {
        if places.contains(path, home) && places.contains(home, path) {
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
        var problem: String? { problem(home: NSHomeDirectory(), places: Places(leads: [:])) }

        func problem(home: String, places: Places) -> String? {
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
                    "“\(covered[0].name)” is already included in \(FolderDrop.displayName(covered[0].container, home: home, places: places)).")
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
