import Foundation
import Observation
import RestoreyCore

/// Settings → Network's edits (`NetworkEdit`, where every decision is made), the save in flight, and the Location
/// question asked when a Wi-Fi network is first added (UI design §6.3). Held by the Settings window
/// (`NetworkEditorSlot`), so going to another section and back keeps unsaved edits; closing the window or quitting
/// asks about them first, as for a plan's (`WindowRouter.askToSave`).
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

    @ObservationIgnored private let supervisor: AgentSupervisor
    @ObservationIgnored let location: LocationAccessState

    init(settings: NetworkSettings, supervisor: AgentSupervisor, location: LocationAccessState) {
        edit = NetworkEdit(settings: settings)
        self.supervisor = supervisor
        self.location = location
    }

    var fields: NetworkEdit.Fields {
        get { edit.fields }
        set {
            edit.fields = newValue
            saveError = nil
        }
    }

    var access: WiFiNameAccess { location.access }

    /// The problem with the name typed, shown once something is typed.
    var newNameProblem: String? { newName.isEmpty ? nil : edit.newNameProblem(newName) }

    /// The agent sent newer settings.
    func rebase(on settings: NetworkSettings) { edit.rebase(on: settings) }

    func remove(_ name: String) {
        edit.remove(name: name)
        saveError = nil
    }

    func revert() {
        edit.revert()
        saveError = nil
    }

    /// Adds the typed name. The first time, while the agent has never been asked, the agent asks macOS for Location
    /// permission first, and the name is added only once it is allowed (the "ask now?" decision is `addStep`). The
    /// name is the one submitted: it is taken before asking, and the field is disabled while the question is up.
    func addName() async {
        let name = newName
        guard !asking, edit.newNameProblem(name) == nil else { return }
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
                location.answered(now)
                switch now {
                case .allowed: break
                case .notAsked, .checking:
                    addNote = WiFiNameAccess.unanswered
                    return
                case .refused, .restricted, .servicesOff:
                    // The list's note says why.
                    return
                }
            case .failure(let error):
                addNote = FormValidation.sentence(error.description) + " The network wasn’t added."
                return
            }
        }
        if edit.add(name: name) {
            if newName == name { newName = "" }
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

/// Whether Restorey can see Wi-Fi names, as the Network pane shows it: the agent's `locationAccess` answer (asked
/// when the pane appears and whenever Restorey comes to the front, since the user may have changed Location in
/// System Settings), else its hello. The answer carries the full status, so a restriction is told apart from a
/// refusal; the hello's Bool can't.
@MainActor
@Observable
final class LocationAccessState {
    private var checked: WiFiNameAccess?
    @ObservationIgnored private let supervisor: AgentSupervisor

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    var access: WiFiNameAccess { checked ?? WiFiNameAccess(hello: supervisor.lastHello) }

    /// Asks the agent now, never prompting. A failed call leaves the hello's answer.
    func refresh() async {
        switch await supervisor.connection.locationAccess() {
        case .success(let reply): checked = WiFiNameAccess(reply: reply)
        case .failure: checked = nil
        }
    }

    /// The answer to a Location question just asked.
    func answered(_ access: WiFiNameAccess) { checked = access }
}

/// Holds the Network section's model and Location state while the Settings window is open. The router reads it to
/// ask about unsaved edits when the window closes or Restorey quits.
@MainActor
@Observable
final class NetworkEditorSlot {
    var model: NetworkEditModel?
    let location: LocationAccessState

    init(supervisor: AgentSupervisor) {
        location = LocationAccessState(supervisor: supervisor)
    }

    /// The edits go with the window.
    func close() { model = nil }
}
