import AppKit
import OSLog
import RestoreyCore

/// The menu bar icon for each `StatusIconState` (UI design §5): the "Layers" glyph, which matches the app icon. Three
/// stacked snapshot layers fade back in time (the newest full, the next 70 %, the oldest 45 %); the top slot says what
/// is happening. Idle shows the newest layer; while backing up it lifts away as an arrow; paused shows a pause mark;
/// needs attention a "!"; and a problem that stops backups an "×". The two older layers never change, so the icon
/// keeps its size and place in the menu bar from state to state.
///
/// The art is in `App/Assets.xcassets` as vector SVG template images (black with partial alpha). A template image is
/// drawn from its alpha channel ("You can use the alpha channel in the image to adjust the opacity of black content",
/// `NSImage.isTemplate`), so the menu bar tints it for light and dark, dims it on an inactive display, and keeps the
/// fade. `verify-bundle.sh` checks every name below is in the built `Assets.car`.
@MainActor
enum StatusIcon {
    static func image(for state: StatusIconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = make(state)
        cache[state] = image
        return image
    }

    private static var cache: [StatusIconState: NSImage] = [:]

    static func accessibilityDescription(for state: StatusIconState) -> String {
        switch state {
        case .ok: "Restorey"
        case .backingUp: "Restorey: backing up"
        case .paused: "Restorey: paused"
        case .warning: "Restorey: needs attention"
        case .error: "Restorey: a problem stops backups"
        }
    }

    /// The asset catalog image for each state.
    static func assetName(for state: StatusIconState) -> String {
        switch state {
        case .ok: "StatusIdle"
        case .backingUp: "StatusBackingUp"
        case .paused: "StatusPaused"
        case .warning: "StatusAttention"
        case .error: "StatusError"
        }
    }

    private static func make(_ state: StatusIconState) -> NSImage {
        let name = assetName(for: state)
        let image: NSImage
        if let asset = NSImage(named: name)?.copy() as? NSImage {
            image = asset
        } else {
            // A missing image is a broken build, which verify-bundle.sh rejects. Should one ship anyway, the status item
            // still needs something to click, so log it and fall back to the nearest system symbol.
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "Restorey", category: "app")
                .fault("\(name, privacy: .public) is missing from the app's asset catalog")
            image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil) ?? NSImage()
        }
        // The catalog marks these as templates; set it again so the tinting never depends on that one setting.
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: state)
        return image
    }
}
