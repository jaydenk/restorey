import AppKit
import Observation
import RestoreyCore
import UniformTypeIdentifiers

/// One opening of a plan's recovery kit: the agent's `recoveryKit` reply made into a `RecoveryKitDocument`, and
/// what copying, printing and saving it did. The document holds the plan's secrets, so it lives only here, and
/// `close()` (the setup step going, or the window closing) drops it. Nothing in it is logged or saved except the
/// PDF the user asks for, where they pick.
///
/// Whoever opens it decides whether it may load: setup only once the repository's own password is saved, the
/// kit window only after `OwnerAuthentication`.
@MainActor
@Observable
final class RecoveryKitModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(RecoveryKitDocument)
        /// The agent's sentence (a refused kit names the missing Keychain item; a partial kit is never shown).
        case failed(String)
    }

    let planID: UUID
    private(set) var state: State = .idle
    /// Set after a PDF is saved on the Mac's own disk: the warning names it until the kit closes.
    private(set) var savedOnThisMac: URL?
    private(set) var exportError: String?
    /// The label of the field just copied, for a moment's "Copied".
    private(set) var copied: String?
    /// Whether the secrets show (`SecretReveal`): the button keeps them shown, Option peeks, and they go back to
    /// dots when the window stops being key or the kit closes. Whoever opened the kit has already confirmed the
    /// owner (or, in setup, needs not), so the button never asks.
    private(set) var reveal = SecretReveal()

    @ObservationIgnored private let connection: AgentConnection

    init(planID: UUID, connection: AgentConnection) {
        self.planID = planID
        self.connection = connection
    }

    var document: RecoveryKitDocument? {
        if case .loaded(let document) = state { return document }
        return nil
    }

    /// Fetches the plan's secrets from the agent and makes the kit. A failure is shown as the agent's sentence.
    func load() async {
        guard state != .loading else { return }
        state = .loading
        exportError = nil
        switch await connection.recoveryKit(planID) {
        case .success(let secrets):
            // The window may have closed while the agent answered: then the secrets aren't kept.
            guard state == .loading else { return }
            state = .loaded(RecoveryKitDocument.make(secrets, createdAt: Date()))
        case .failure(let error):
            guard state == .loading else { return }
            state = .failed(FormValidation.sentence(error.description))
        }
    }

    /// Whether the agent's secrets for the plan are still the ones shown (nil when it can't say). The kit window
    /// asks before confirming, so a kit can't be confirmed while a change saved since (in Settings, say) left
    /// it holding old keys; a different answer replaces the kit shown.
    func stillCurrent() async -> Bool? {
        guard let shown = document else { return nil }
        guard case .success(let secrets) = await connection.recoveryKit(planID), document != nil else { return nil }
        let current = RecoveryKitDocument.make(secrets, createdAt: shown.createdAt)
        if current.sections == shown.sections { return true }
        state = .loaded(RecoveryKitDocument.make(secrets, createdAt: Date()))
        savedOnThisMac = nil
        return false
    }

    /// The secrets go now, not when SwiftUI lets go of the view.
    func close() {
        state = .idle
        savedOnThisMac = nil
        copied = nil
        reveal.reset()
    }

    func toggleReveal() { reveal.toggle() }
    func revealByButton() { reveal.approvedByButton() }
    func optionChanged(_ held: Bool) { reveal.optionChanged(held) }
    func resignedKey() { reveal.resignedKey() }
    func becameKey() { reveal.becameKey() }

    func copy(_ field: RecoveryKitDocument.Field) {
        ConcealedPasteboard.copy(field.value, concealed: field.isSecret)
        showCopied(field.label)
    }

    /// "Copied" for a moment. Only the label is kept, never the value, so nothing secret outlives `close()`.
    private func showCopied(_ label: String) {
        copied = label
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copied == label { self?.copied = nil }
        }
    }

    func print() {
        guard let document else { return }
        RecoveryKitExport.print(document)
    }

    /// "Save as PDF…": a save panel with no folder chosen for the user (never Downloads by default), then the
    /// internal-disk warning when the folder picked is on this Mac's own disk.
    func savePDF() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recovery Kit"
        panel.message = "Save it somewhere other than this Mac, such as a drive you keep elsewhere."
        panel.nameFieldStringValue = RecoveryKitExport.fileName(document)
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RecoveryKitExport.savePDF(document, to: url)
            exportError = nil
            savedOnThisMac = RecoveryKitExport.isOnInternalDisk(url) ? url : nil
        } catch {
            exportError = String(describing: error)
        }
    }

    func showSavedCopyInFinder() {
        guard let savedOnThisMac else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedOnThisMac])
    }
}
