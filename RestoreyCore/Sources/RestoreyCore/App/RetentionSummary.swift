import Foundation

/// The plain-English line under the Retention tab's counts (Task 16a), and the note about the weekly check.
///
/// The wording follows restic 0.19.1's `forget` documentation (doc/060_forget.rst): `--keep-hourly n` is "for the last
/// n hours which have one or more snapshots, keep only the most recent one for each hour", and likewise for days,
/// weeks and months, on natural boundaries (weeks run Monday to Sunday). So the count is of periods that *have* a
/// backup, not of the last n hours of wall time. A snapshot kept by any rule is kept ("the results are ORed"), and a
/// rule of 0 is off. These are the rules `makeInvocation(.forget…)` passes (`--keep-hourly` … `--keep-monthly`).
public enum RetentionSummary {
    /// The sentence for `retention`, and when it is removed: after each backup, or once a day for an adopted
    /// repository tidied daily (`ForgetCadence`).
    public static func text(retention: Retention, cadence: ForgetCadence, locale: Locale) -> String {
        let rules: [(count: Int, each: String, unit: String)] = [
            (retention.hourly, "hour", "hours"), (retention.daily, "day", "days"),
            (retention.weekly, "week", "weeks"), (retention.monthly, "month", "months"),
        ]
        let clauses = rules.filter { $0.count > 0 }.map { rule -> String in
            if rule.count == 1 { return "the latest \(rule.each) that has one" }
            let number = rule.count.formatted(.number.locale(locale))
            return "each \(rule.each) for the last \(number) \(rule.unit) that have one"
        }
        // Restic refuses an empty policy rather than removing anything, so the form never saves one; say what it would
        // mean in case one is shown.
        guard let last = clauses.last else { return "Keeps every backup. Nothing is removed." }
        let list = clauses.count == 1 ? last : clauses.dropLast().joined(separator: ", ") + " and " + last
        let when = cadence == .daily ? "once a day" : "after each backup"
        return "Keeps the newest backup of \(list). The rest are removed \(when)."
    }

    /// The summary of the retention the form holds as typed, or nil while it doesn't read as a policy (the form shows
    /// the problem itself).
    public static func text(form: ScheduleForm, cadence: ForgetCadence, locale: Locale) -> String? {
        guard case .success(let retention) = form.retention else { return nil }
        return text(retention: retention, cadence: cadence, locale: locale)
    }

    /// What the weekly `restic check` (no `--read-data`) costs. Verified in restic 0.19.1: `cmd_check.go` makes a
    /// temporary cache that is deleted afterwards (`--with-cache` would reuse the real one), so it loads the snapshots,
    /// the index files and the tree blobs (folder lists) from the repository each time; `Checker.Packs` only lists the
    /// pack files and compares their sizes with the index; no data pack is read unless `--read-data` or
    /// `--read-data-subset` is given (`buildPacksFilter` is nil), and restic's own docs say only `--read-data` has to
    /// download every pack. No sizes are stated: they depend on the repository.
    public static let weeklyCheckNote =
        "Once a week Restorey checks the backup’s structure. It downloads indexes and folder lists, not your "
        + "files, so it uses little data."
}
