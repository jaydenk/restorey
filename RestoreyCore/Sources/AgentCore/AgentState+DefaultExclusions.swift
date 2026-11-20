import Foundation
import RestoreyCore

/// Default exclusions added since a plan was made reach it once.
extension AgentState {
    // MARK: New default exclusions

    /// Adds to each plan the default folder exclusions added since its `exclusionDefaultsRevision`
    /// (`DefaultExclusions.additions(after:home:)`) that it doesn't already list, word for word, at the end of its
    /// `exclusions`, and moves its revision on to `DefaultExclusions.revision` (owner, 20 Nov 2026). Nothing is
    /// removed or changed, so a default the person removed later stays removed. Called once at startup, after the
    /// config is loaded and before the agent listens (`main.swift`): the agent knows the home folder, the schema
    /// migration doesn't. One write for all the plans, none when no plan is behind, and none in the config-error
    /// state. Each plan given a pattern gets a line in the agent's log; a failed write is logged and changes nothing,
    /// so the next start tries again.
    public func addNewDefaultExclusions(home: URL) async {
        guard loadError == nil else { return }
        do {
            let added = try await serialisedWrite { () async throws -> [(plan: String, patterns: [String])] in
                var updated = config
                var added: [(plan: String, patterns: [String])] = []
                for index in updated.plans.indices {
                    let plan = updated.plans[index]
                    guard plan.exclusionDefaultsRevision < DefaultExclusions.revision else { continue }
                    let missing = DefaultExclusions.additions(after: plan.exclusionDefaultsRevision, home: home)
                        .filter { !plan.exclusions.contains($0) }
                    updated.plans[index].exclusions += missing
                    updated.plans[index].exclusionDefaultsRevision = DefaultExclusions.revision
                    if !missing.isEmpty { added.append((plan.name, missing)) }
                }
                if updated != config { try await saveConfig(updated) }
                return added
            }
            for (plan, patterns) in added {
                agentLog("Added the new default exclusions to plan “\(plan)”: \(patterns.joined(separator: ", "))")
            }
        } catch {
            let detail = (error as? AgentError)?.message ?? "\(error)"
            agentLog("Restorey couldn’t add the new default exclusions to the plans, and will try again at the next "
                + "start: \(detail)")
        }
    }
}
