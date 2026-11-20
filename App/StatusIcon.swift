import AppKit
import OSLog
import RestoreyCore

/// The menu bar icon for each `StatusIconState`: the system's drive symbol with the state as a badge in its bottom-right
/// corner (owner, 20 Nov 2026; `docs/superpowers/specs/2026-11-20-menu-bar-icon-design.md`). Up to date shows a tick;
/// backing up an up arrow; paused a pause mark; needs attention a "!"; a problem that stops backups an "×". Nothing to
/// report yet (`.idle`: a plan with no backup yet, or Restorey still connecting) is the drive alone.
///
/// The drive is SF Symbols' `externaldrive` at its default size, which is the size and weight of the system's own menu
/// bar symbols (`wifi` is 18 × 13 pt too). The badge is a filled circle symbol, 72 % of the drive's height, drawn over a
/// circle cleared out of the drive with a 1.5 pt gap, so it reads apart from the outline. Every state uses one canvas,
/// with the drive in the same place, so the icon never changes width or moves. The images are templates: the menu bar
/// tints them for light and dark and dims them on an inactive display (owner, 12 Nov 2026: a monochrome menu bar).
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
        case .idle, .ok: "Restorey"
        case .backingUp: "Restorey: backing up"
        case .paused: "Restorey: paused"
        case .warning: "Restorey: needs attention"
        case .error: "Restorey: a problem stops backups"
        }
    }

    /// The SF Symbol drawn in the drive's bottom-right corner, or nil for the drive alone. Every name was checked to
    /// exist on macOS 27.2 with `NSImage(systemSymbolName:accessibilityDescription:)` (20 Nov 2026).
    static func badgeName(for state: StatusIconState) -> String? {
        switch state {
        case .idle: nil
        case .ok: "checkmark.circle.fill"
        case .backingUp: "arrow.up.circle.fill"
        case .paused: "pause.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    static let driveName = "externaldrive"
    /// The badge's side as a share of the drive's height, and the gap cleared around it (pt), chosen against the
    /// system's `wifi` and `battery.100percent` symbols at menu bar size.
    private static let badgeRatio: CGFloat = 0.72
    private static let badgeGap: CGFloat = 1.5

    /// The canvas when the drive symbol is missing: the size of the drive's canvas at menu bar size, so the status
    /// item keeps its width and stays clickable.
    private static let fallbackSize = NSSize(width: 22, height: 16)

    private static func make(_ state: StatusIconState) -> NSImage {
        let image = symbol(driveName).map { drawn(state, drive: $0) } ?? fallback()
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: state)
        return image
    }

    private static func drawn(_ state: StatusIconState, drive: NSImage) -> NSImage {
        let side = (drive.size.height * badgeRatio).rounded()
        // Room for the badge to overhang the drive's bottom-right corner, the same for every state.
        let size = NSSize(
            width: (drive.size.width + side * 0.45).rounded(), height: (drive.size.height + side * 0.3).rounded())
        let badge = badgeName(for: state).flatMap(symbol)
        return NSImage(size: size, flipped: false) { rect in
            let driveRect = NSRect(
                x: 0, y: rect.maxY - drive.size.height, width: drive.size.width, height: drive.size.height)
            guard let badge, let context = NSGraphicsContext.current else {
                drive.draw(in: driveRect)
                return true
            }
            let badgeRect = NSRect(x: rect.maxX - side, y: 0, width: side, height: side)
            // The drive and its cut-out in a layer of their own, so the destination-out clears only the drive, never
            // whatever the image is drawn over.
            context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            drive.draw(in: driveRect)
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -badgeGap, dy: -badgeGap)).fill()
            context.compositingOperation = .sourceOver
            context.cgContext.endTransparencyLayer()
            badge.draw(in: badgeRect)
            return true
        }
    }

    /// The letter "R" in the menu bar's font, centred on `fallbackSize`, for every state: the tooltip and the
    /// accessibility description still say the state.
    private static func fallback() -> NSImage {
        let letter = NSAttributedString(
            string: "R", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black])
        return NSImage(size: fallbackSize, flipped: false) { rect in
            let text = letter.size()
            letter.draw(at: NSPoint(x: rect.midX - text.width / 2, y: rect.midY - text.height / 2))
            return true
        }
    }

    /// Nil only on a build for an older macOS than the target, since the names are fixed and checked. Logged. A missing
    /// badge leaves the plain drive (the tooltip and accessibility description still say the state); a missing drive
    /// leaves the letter "R" (`fallback`).
    private static func symbol(_ name: String) -> NSImage? {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return image }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Restorey", category: "app")
            .fault("SF Symbol \(name, privacy: .public) is missing")
        return nil
    }
}
