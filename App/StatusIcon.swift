import AppKit
import RestoreyCore

/// The menu bar icon for each `StatusIconState` (UI design §5), from SF Symbols. Every symbol name here was checked
/// to exist on macOS 27.2 with `NSImage(systemSymbolName:accessibilityDescription:)` (Task 8 report).
///
/// Every state is a template image (owner, 12 Nov 2026: a monochrome menu bar), so the menu bar tints them for light
/// and dark and dims them on an inactive display (a custom view or explicit colour would not). Error is the only
/// filled drive, which is what sets it apart at a glance.
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

    private static func make(_ state: StatusIconState) -> NSImage {
        let description = accessibilityDescription(for: state)
        switch state {
        case .ok:
            return template("externaldrive.badge.timemachine", description)
        case .backingUp:
            return badged("arrow.up.circle", description)
        case .paused:
            return badged("pause.circle", description)
        case .warning:
            // Not `externaldrive.trianglebadge.exclamationmark`: its triangle is filled, and only error is filled.
            return badged("exclamationmark.triangle", description)
        case .error:
            return template("externaldrive.fill.badge.xmark", description)
        }
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        // The names are fixed and checked; a missing one would be a build for an older macOS than the target.
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    private static func template(_ name: String, _ description: String) -> NSImage {
        let image = symbol(name, description)
        image.isTemplate = true
        return image
    }

    /// The plain drive with `badge` in the bottom-left corner, where `externaldrive.badge.timemachine` has its clock.
    /// SF Symbols has no drive with an upload, pause or outlined warning badge, so the two are drawn together, the
    /// badge cut out of the drive with a small gap. The canvas is the OK icon's size, so the icon doesn't change
    /// width between states.
    private static func badged(_ badgeName: String, _ description: String) -> NSImage {
        let size = template("externaldrive.badge.timemachine", description).size
        let drive = symbol("externaldrive", description)
        let badge = symbol(badgeName, description)
        let image = NSImage(size: size, flipped: false) { rect in
            let driveRect = NSRect(
                x: rect.maxX - drive.size.width, y: (rect.height - drive.size.height) / 2,
                width: drive.size.width, height: drive.size.height)
            drive.draw(in: driveRect)
            let side = (rect.height * 0.62).rounded()
            let badgeSize = NSSize(width: side, height: side * badge.size.height / max(badge.size.width, 1))
            let badgeRect = NSRect(origin: NSPoint(x: 0, y: 0), size: badgeSize)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: badgeRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
