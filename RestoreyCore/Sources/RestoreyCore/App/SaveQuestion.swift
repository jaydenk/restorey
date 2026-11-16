import Foundation

/// The Save, Don't Save or Cancel question asked when Settings closes or Restorey quits with unsaved edits (Ruling R1,
/// fix round 2; the Network section since Task 15 fix round 1). The app shows it as a sheet on the Settings window.
public struct SaveQuestion: Sendable, Equatable {
    public var message: String
    public var information: String

    public init(message: String, information: String) {
        self.message = message
        self.information = information
    }

    private static let lost = "If you don't save, your changes are lost."

    public static func plan(name: String, pausesBackups: Bool) -> SaveQuestion {
        SaveQuestion(
            message: "Do you want to save the changes to “\(name)”?",
            information: pausesBackups ? "\(PlanEdit.pauseWarning) \(lost)" : lost)
    }

    public static let network = SaveQuestion(
        message: "Do you want to save the changes to the network settings?", information: lost)
}

/// A Settings section with unsaved edits, asked about in turn when the window closes or Restorey quits.
public enum UnsavedSettings: Sendable, Equatable {
    case plan
    case network

    /// What to ask about, the plan first: its question names it, and a refused save shows where it was refused.
    public static func toAsk(plan: Bool, network: Bool) -> [UnsavedSettings] {
        (plan ? [.plan] : []) + (network ? [.network] : [])
    }

    /// Where a refused save is shown, with why.
    public var section: SettingsSection {
        switch self {
        case .plan: .plans
        case .network: .network
        }
    }
}
