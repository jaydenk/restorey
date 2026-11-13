import Foundation

/// Setup's "Schedule" step (UI design §4 step 6): how often, the battery rule and retention. The check-in URL
/// is a secret, so it is typed into a `SecretField` and only checked here (`checkInProblem`). The retention
/// fields are text so a half-typed number can be shown with its sentence; each problem ends with a full stop.
public struct ScheduleForm: Sendable, Equatable {
    /// The intervals offered, in hours. Hourly is the default (product spec §5.5).
    public static let intervalHours = [1, 2, 4, 6, 12, 24]

    /// The battery rules offered: a minimum charge, or never on battery. 20% is the default (§5.5).
    public static let batteryChoices: [BatteryRule] = [
        .minimumPercent(0), .minimumPercent(10), .minimumPercent(20), .minimumPercent(50), .neverOnBattery,
    ]

    public var intervalHours: Int
    public var battery: BatteryRule
    public var hourly: String
    public var daily: String
    public var weekly: String
    public var monthly: String

    /// The form showing `plan`'s schedule. An interval that isn't one of the choices (set elsewhere) is shown
    /// as the nearest choice at or above it.
    public init(plan: Plan) {
        let seconds: Int
        switch plan.schedule {
        case .interval(let value): seconds = value
        }
        let hours = max(1, Int((Double(seconds) / 3600).rounded(.up)))
        intervalHours = Self.intervalHours.first { $0 >= hours } ?? Self.intervalHours.last!
        battery = Self.batteryChoices.contains(plan.conditions.battery) ? plan.conditions.battery : .minimumPercent(20)
        hourly = String(plan.retention.hourly)
        daily = String(plan.retention.daily)
        weekly = String(plan.retention.weekly)
        monthly = String(plan.retention.monthly)
    }

    public static func title(hours: Int) -> String {
        switch hours {
        case 1: "Every hour"
        case 24: "Once a day"
        default: "Every \(hours) hours"
        }
    }

    public static func title(battery: BatteryRule) -> String {
        switch battery {
        case .minimumPercent(let percent) where percent <= 0: "Always"
        case .minimumPercent(let percent): "Above \(percent)%"
        case .neverOnBattery: "Never"
        }
    }

    /// A retention count: a whole number from 0 to 9,999.
    public static func countProblem(_ text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(typed), typed.allSatisfy(\.isASCII), (0...9999).contains(value) else {
            return "Enter a whole number from 0 to 9999."
        }
        return nil
    }

    /// The retention as typed, or the sentence for the first problem: each a count, and not all 0 (restic's
    /// `forget` keeps nothing it is asked to keep, so all zeros would leave nothing to restore).
    public var retention: Result<Retention, FormValidation.Problem> {
        let fields = [hourly, daily, weekly, monthly]
        if let problem = fields.lazy.compactMap(Self.countProblem).first { return .failure(.init(problem)) }
        let values = fields.map { Int($0.trimmingCharacters(in: .whitespaces))! }
        guard values.contains(where: { $0 > 0 }) else {
            return .failure("Keep at least one snapshot: set one of these above 0.")
        }
        return .success(Retention(hourly: values[0], daily: values[1], weekly: values[2], monthly: values[3]))
    }

    /// `plan` with this form's schedule, battery rule and retention, or the retention's problem.
    public func applied(to plan: Plan) -> Result<Plan, FormValidation.Problem> {
        retention.map { retention in
            var plan = plan
            plan.schedule = .interval(seconds: intervalHours * 3600)
            plan.conditions.battery = battery
            plan.retention = retention
            return plan
        }
    }

    /// The optional check-in URL: empty is none; otherwise an http or https address, http only for a host on
    /// this Mac, the local network or Tailscale (the endpoint's rule).
    public static func checkInProblem(_ text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return nil }
        guard let components = URLComponents(string: typed), let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty
        else { return "The check-in URL is a web address starting with https://." }
        if scheme == "http", !FormValidation.isLocalHost(host) {
            return "Use https:// for a check-in service outside your local network."
        }
        return nil
    }

    /// Why the check-in URL is worth adding (product spec §6.2): shown beside the field.
    public static let checkInExplanation =
        "A check-in service such as Healthchecks.io emails you when backups stop arriving. It's the only way to "
        + "find out that this Mac is off, broken or stolen, or that Restorey itself has stopped. Set the check's "
        + "period and grace to a few days, not an hour, so a Mac that skips backups on battery doesn't raise false "
        + "alarms. Without one, the menu shows “No off-Mac monitoring”."
}
