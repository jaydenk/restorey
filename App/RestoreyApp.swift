import AppKit
import RestoreyCore
import SwiftUI

@main
struct RestoreyApp: App {
    var body: some Scene {
        MenuBarExtra("Restorey", systemImage: "externaldrive.badge.timemachine") {
            Text("Restorey")
            Divider()
            Button("Quit Restorey") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
