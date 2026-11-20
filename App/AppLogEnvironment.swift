import RestoreyCore
import SwiftUI

extension EnvironmentValues {
    /// The app's log (`app.log`, the one `AgentSupervisor` writes to), for views that record what they did, such as an
    /// add to a plan's lists judged by path because the disk didn't answer (L157). Set at each window's root; nil
    /// where there is no installed copy, which shows none of those views.
    @Entry var appLog: AppLog? = nil
}
