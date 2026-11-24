import Foundation

/// The Save, Don't Save or Cancel question asked when the main window closes or Restorey quits with unsaved plan
/// edits (Ruling R1, fix round 2). The app shows it as a sheet on the main window.
public struct SaveQuestion: Sendable, Equatable {
    public var message: String
    public var information: String

    public init(message: String, information: String) {
        self.message = message
        self.information = information
    }

    private static let lost = "If you don’t save, your changes are lost."

    public static func plan(name: String, pausesBackups: Bool) -> SaveQuestion {
        SaveQuestion(
            message: "Do you want to save the changes to “\(name)”?",
            information: pausesBackups ? "\(PlanEdit.pauseWarning) \(lost)" : lost)
    }
}

/// A section with unsaved edits, asked about when the main window closes or Restorey quits.
public enum UnsavedSettings: Sendable, Equatable {
    case plan

    /// What to ask about.
    public static func toAsk(plan: Bool) -> [UnsavedSettings] {
        plan ? [.plan] : []
    }

    /// Where a refused save is shown, with why.
    public var section: MainSection {
        switch self {
        case .plan: .plans
        }
    }
}
