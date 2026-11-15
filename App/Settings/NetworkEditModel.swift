import Foundation
import Observation
import RestoreyCore

/// Settings → Network's edits (`NetworkEdit`, where every decision is made), the save in flight, and the Location
/// question asked when a Wi-Fi network is first added (UI design §6.3). Held by the Settings window
/// (`NetworkEditorSlot`), so going to another section and back keeps unsaved edits; closing the window drops them.
@MainActor
@Observable
final class NetworkEditModel {
    private(set) var edit: NetworkEdit
    private(set) var saving = false
    /// The last save's sentence. Any edit clears it, so it never hides the current problem.
    private(set) var saveError: String?
    /// The agent is waiting for the user to answer macOS's Location question.
    private(set) var asking = false
    /// What the last "Add" found, when it added nothing and the list's note doesn't already say why.
    private(set) var addNote: String?
    /// The name typed to add, kept as typed (the text fields' binding rule).
    var newName = "" {
        didSet { if newName != oldValue { addNote = nil } }
    }

    /// The agent's answer to the last Location question, until the next hello says the same or the user comes back
    /// to Restorey (the answer can change in System Settings).
    @ObservationIgnored private var answered: WiFiNameAccess?
    @ObservationIgnored private let supervisor: AgentSupervisor

    init(settings: NetworkSettings, supervisor: AgentSupervisor) {
        edit = NetworkEdit(settings: settings)
        self.supervisor = supervisor
    }

    var fields: NetworkEdit.Fields {
        get { edit.fields }
        set {
            edit.fields = newValue
            saveError = nil
        }
    }

    /// Whether Restorey can see Wi-Fi names: the agent's last answer to a question, else its hello.
    var access: WiFiNameAccess { answered ?? WiFiNameAccess(hello: supervisor.lastHello) }

    /// The problem with the name typed, shown once something is typed.
    var newNameProblem: String? { newName.isEmpty ? nil : edit.newNameProblem(newName) }

    /// The agent sent newer settings.
    func rebase(on settings: NetworkSettings) { edit.rebase(on: settings) }

    /// Restorey came back to the front: the user may have changed Location in System Settings.
    func reread() async {
        answered = nil
        await supervisor.refreshHello()
    }

    func remove(_ name: String) {
        edit.remove(name: name)
        saveError = nil
    }

    func revert() {
        edit.revert()
        saveError = nil
    }

    /// Adds the typed name. The first time, while the agent has never been asked, the agent asks macOS for Location
    /// permission first, and the name is added only once it is allowed (the "ask now?" decision is `addStep`).
    func addName() async {
        guard !asking, edit.newNameProblem(newName) == nil else { return }
        switch access.addStep {
        case .blocked:
            return
        case .add:
            break
        case .askFirst:
            asking = true
            let result = await supervisor.connection.requestLocationPermission()
            asking = false
            switch result {
            case .success(let reply):
                let now = WiFiNameAccess(reply: reply)
                answered = now
                await supervisor.refreshHello()
                if WiFiNameAccess(hello: supervisor.lastHello) == now { answered = nil }
                switch now {
                case .allowed: break
                case .notAsked, .checking:
                    addNote = WiFiNameAccess.unanswered
                    return
                case .refused, .servicesOff:
                    // The list's note says why, with the button to System Settings.
                    return
                }
            case .failure(let error):
                addNote = FormValidation.sentence(error.description) + " The network wasn't added."
                return
            }
        }
        if edit.add(name: newName) {
            newName = ""
            saveError = nil
        }
    }

    /// Sends the edits; on success the form starts again from what the agent saved (names trimmed). A refusal keeps
    /// everything as typed.
    func save() async {
        guard !saving else { return }
        let request: NetworkSettings
        switch edit.request() {
        case .failure(let problem):
            saveError = problem.message
            return
        case .success(let built):
            request = built
        }
        saving = true
        saveError = nil
        defer { saving = false }
        switch await supervisor.connection.saveNetworkSettings(request) {
        case .success(let status):
            edit.didSave(status.network ?? request.normalised())
        case .failure(let error):
            saveError = FormValidation.sentence(error.description)
        }
    }
}

/// Holds the Network section's model while the Settings window is open.
@MainActor
@Observable
final class NetworkEditorSlot {
    var model: NetworkEditModel?
}
