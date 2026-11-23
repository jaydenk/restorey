import Foundation
import Observation
import RestoreyCore

/// Settings → Network's edits (`NetworkEdit`, where every decision is made), the save in flight, and the Location
/// question asked when a Wi-Fi network is first added (UI design §6.3). Changes apply as they are made. Held by the
/// Settings window (`NetworkEditorSlot`), so going to another section and back keeps an edit the agent refused; it
/// goes with the window, and nothing asks about it.
@MainActor
@Observable
final class NetworkEditModel {
    private(set) var edit: NetworkEdit
    private(set) var saving = false
    /// A commit was asked for while a save was in flight.
    @ObservationIgnored private var commitAgain = false
    /// The last save's sentence. Any edit clears it, so it never hides the current problem.
    private(set) var saveError: String?
    /// The agent is waiting for the user to answer macOS's Location question.
    private(set) var asking = false
    /// A speed test was asked for and hasn't come back (the agent's own `testing` flag covers the daily and
    /// pre-backup ones).
    private(set) var testRequested = false
    /// The sentence a refused "Test now" came back with.
    private(set) var testError: String?
    /// Why asking the agent about Location, for a percentage, failed.
    private(set) var locationError: String?
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

    /// The current network's measurement, as the agent last reported it.
    var uploadSpeed: UploadSpeedStatus? { supervisor.lastKnownStatus?.uploadSpeed }

    /// "Test now" is off while any test runs.
    var testing: Bool { testRequested || uploadSpeed?.testing == true }

    /// The line under a percentage when Wi-Fi networks can't be told apart; nil while the question is up.
    var percentNote: String? {
        guard fields.limitKind == .percent, !asking else { return nil }
        return locationError ?? access.percentNote
    }

    /// The problem with the name typed, shown once something is typed.
    var newNameProblem: String? { newName.isEmpty ? nil : edit.newNameProblem(newName) }

    /// The agent sent newer settings.
    func rebase(on settings: NetworkSettings) { edit.rebase(on: settings) }

    /// Chooses the kind of limit. A percentage needs the Wi-Fi name to tell networks apart, so choosing it while the
    /// agent isn't authorised has the agent request Location permission (macOS shows its question only if it has
    /// never been answered; otherwise the reply just tells the current state). If it is refused the choice stands:
    /// `percentNote` says what that means.
    func setLimitKind(_ kind: LimitKind) async {
        edit.setLimitKind(kind)
        saveError = nil
        locationError = nil
        if kind == .percent, !asking, access != .allowed {
            _ = await askForLocation(onFailure: { [self] in locationError = FormValidation.sentence($0) })
        }
        await commit()
    }

    /// Runs a speed test now and shows its refusal, if it has one. A test's own failure comes back in the status
    /// and shows on the speed line.
    func testNow() async {
        guard !testing else { return }
        testRequested = true
        testError = nil
        defer { testRequested = false }
        if case .failure(let error) = await supervisor.connection.runUploadSpeedTest() {
            testError = FormValidation.sentence(error.description)
        }
    }

    /// Asks the agent to request Location permission and records the answer. True when it is allowed.
    private func askForLocation(onFailure: (String) -> Void) async -> Bool {
        asking = true
        let result = await supervisor.connection.requestLocationPermission()
        asking = false
        switch result {
        case .success(let reply):
            let now = WiFiNameAccess(reply: reply)
            location.answered(now)
            return now == .allowed
        case .failure(let error):
            onFailure(error.description)
            return false
        }
    }

    func remove(_ name: String) async {
        edit.remove(name: name)
        saveError = nil
        await commit()
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
            addNote = nil
            let allowed = await askForLocation(onFailure: { [self] in
                addNote = FormValidation.sentence($0) + " The network wasn’t added."
            })
            guard allowed else {
                switch access {
                case .notAsked, .checking:
                    // Answered neither way (not in time, or no question was shown), unless the call failed above.
                    if addNote == nil { addNote = WiFiNameAccess.unanswered }
                case .allowed, .refused, .restricted, .servicesOff:
                    // The list's note says why.
                    break
                }
                return
            }
        }
        if edit.add(name: name) {
            if newName == name { newName = "" }
            saveError = nil
            await commit()
        }
    }

    /// Applies the edits as the user goes: a toggle or picker at once, a text field when editing ends. `NetworkEdit`
    /// decides what to do (nothing, send the whole set, or stop on a problem). A refusal keeps everything as typed,
    /// so it can be corrected, and `saved` stays as it was.
    ///
    /// Commits are serialised: one asked for while a save is in flight sets `commitAgain`, and the loop that is
    /// sending runs it when that save returns, so a quick second change is never lost and the agent ends with the
    /// last value. The in-flight save was built from the edits as they were; the second is built after it, from
    /// `saved` as the agent then has it.
    func commit() async {
        if saving {
            commitAgain = true
            return
        }
        saving = true
        defer { saving = false }
        repeat {
            commitAgain = false
            await send()
        } while commitAgain
    }

    private func send() async {
        let request: NetworkSettings
        switch edit.commit() {
        case .nothing:
            saveError = nil
            return
        case .problem(let problem):
            saveError = problem
            return
        case .send(let settings):
            request = settings
        }
        saveError = nil
        let sent = edit.fields
        switch await supervisor.connection.saveNetworkSettings(request) {
        case .success(let status):
            // What was changed while this was in flight is kept (`didSave`), and the next pass sends it.
            edit.didSave(status.network ?? request.normalised(), sent: sent)
        case .failure(let error):
            // Switches and menus show what the agent has again; typed text stays to be corrected. Nothing queues:
            // a change asked for meanwhile was made on a form that has just been reset.
            edit.didRefuse()
            commitAgain = false
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

/// Holds the Network section's model and Location state while the Settings window is open.
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
