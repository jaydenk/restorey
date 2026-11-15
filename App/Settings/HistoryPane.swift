import RestoreyCore
import SwiftUI

/// Settings → History (UI design §6.4): every plan's runs, newest first, with a plan filter and an outcome filter.
/// Each plan's own History tab shows the same list fixed to that plan (`HistoryList(planID:)`).
///
/// `filterRequest` is the plan the menu's "Show Details…" asked for. Opened from the toolbar the list starts with
/// every plan: choosing a section clears the request (`SettingsToolbar.choose`), and so does closing the window.
struct HistoryPane: View {
    let filterRequest: HistoryFilterRequest?

    var body: some View {
        HistoryList(planID: nil, filterRequest: filterRequest)
            .padding(16)
    }
}
