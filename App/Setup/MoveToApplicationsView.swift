import RestoreyCore
import SwiftUI

/// The first screen for a copy outside /Applications (UI design §4). It offers to replace a copy already there
/// only while that copy's agent isn't registered; otherwise it asks for the copy to be quit and replaced by hand.
struct MoveToApplicationsView: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to Applications").font(.title2.bold())
            Text(AppMove.explanation)
            switch model.moveDecision {
            case .replace?:
                Label(AppMove.replaceQuestion, systemImage: "exclamationmark.triangle")
            case .refuse?:
                Label(AppMove.refusal, systemImage: "exclamationmark.octagon")
            case .move?, nil:
                EmptyView()
            }
            if let error = model.moveError {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
            SetupButtonRow {
                if model.moving { ProgressView().controlSize(.small) }
                switch model.moveDecision {
                case .refuse?:
                    Button("Quit Restorey") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut(.defaultAction)
                case .replace?:
                    Button("Replace and Move") { Task { await model.moveToApplications() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.moving)
                case .move?, nil:
                    Button("Move to Applications") { Task { await model.moveToApplications() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.moving || model.moveDecision == nil)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshMoveDecision() }
        // The other copy may be quit, set up or removed while this screen waits.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMoveDecision()
        }
    }
}
