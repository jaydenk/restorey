import Foundation
import Testing

/// Final review round 2: nothing the agent runs to build a status, schedule a run or name a folder in an alert may
/// read the disk, since a repository on a network volume that stops answering would stall the agent with it. A stat
/// can't be observed from a test without such a volume, so this pins the source instead: in these files, no
/// `URL(fileURLWithPath:)` without `isDirectory:` (that form stats the path to learn whether it is a folder), and no
/// `standardizedFileURL` or `resolvingSymlinksInPath()` outside the two places allowed to follow links
/// (`SourcePaths.resolvingLinks`, which only `LinkResolver` calls on the agent's side, and `FolderDrop.classify`, which
/// only the app calls). Reintroducing any of them here fails this test.
struct StatusPathPurityTests {
    private static let sources = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)

    private static let files = [
        "RestoreyCore/Config/Plan.swift", "RestoreyCore/Config/SourcePaths.swift",
        "RestoreyCore/Schedule/Schedule.swift", "RestoreyCore/Alerts/AlertPolicy.swift",
        "RestoreyCore/App/MenuPresentation.swift", "RestoreyCore/App/PlanNote.swift", "RestoreyCore/App/FolderDrop.swift",
        "RestoreyCore/Restic/DefaultExclusions.swift", "RestoreyCore/Restic/ResticInvocation.swift",
        "AgentCore/AgentState.swift", "AgentCore/AlertContent.swift", "AgentCore/AgentError.swift",
        "AgentCore/AlertReconciliation.swift", "AgentCore/PlanRunner.swift", "AgentCore/PlanRunner+Policy.swift",
        "AgentCore/SchedulerCore.swift",
    ]

    /// Where following links is allowed: the file and the text of the only lines that may.
    private static let allowed: [String: [String]] = [
        "RestoreyCore/Config/SourcePaths.swift": ["URL(fileURLWithPath: standardised(path), isDirectory: true).resolvingSymlinksInPath()"],
        "RestoreyCore/App/FolderDrop.swift": ["let path = url.standardizedFileURL.path", "let target = url.resolvingSymlinksInPath()"],
    ]

    @Test(arguments: files)
    func readsNothingFromTheDisk(file: String) throws {
        let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { continue }
            if Self.allowed[file, default: []].contains(where: code.contains) { continue }
            #expect(!(code.contains("URL(fileURLWithPath:") && !code.contains("isDirectory:")), "\(file):\(number + 1)")
            #expect(!code.contains("standardizedFileURL"), "\(file):\(number + 1)")
            #expect(!code.contains("resolvingSymlinksInPath"), "\(file):\(number + 1)")
        }
    }
}
