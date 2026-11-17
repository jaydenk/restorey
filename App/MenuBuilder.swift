import AppKit
import RestoreyCore

/// Receives every chosen menu item. `MenuBuilder.command(of:)` says what it asks for.
@MainActor
@objc protocol MenuActionTarget: AnyObject {
    func menuItemChosen(_ sender: NSMenuItem)
}

/// Turns `MenuContent` into the status item's `NSMenuItem`s. Which rows there are, and what they do, is decided in
/// `MenuLayout` (tested in RestoreyCore); this only draws them.
///
/// It can be called while the menu is open: when `MenuLayout.canUpdateInPlace` allows, the existing items are
/// updated where they are, so progress moves under the pointer without losing its highlight or an open submenu;
/// otherwise the items are replaced, which AppKit shows at once in an open menu.
@MainActor
enum MenuBuilder {
    static func build(_ content: MenuContent, into menu: NSMenu, actions: MenuActionTarget, developer: Bool) {
        let rows = MenuLayout.rows(content, developer: developer)
        let shown = menu.items.compactMap { ($0.representedObject as? RowBox)?.row }
        if shown.count == menu.items.count, MenuLayout.canUpdateInPlace(from: shown, to: rows) {
            for (item, row) in zip(menu.items, rows) { update(item, to: row) }
        } else {
            menu.removeAllItems()
            for row in rows { menu.addItem(item(for: row, actions: actions)) }
        }
    }

    /// From `NSMenuDelegate.menu(_:willHighlight:)`. AppKit doesn't recolour an attributed title's explicit
    /// foreground colours when it highlights an item, and the highlight is the accent colour, so accent, red or
    /// orange text (and a coloured image) would vanish on it. The item about to be highlighted is redrawn with the
    /// selected-menu-item text colour and a template image, which the menu tints for the highlight, and the one
    /// losing the highlight gets its colours back. `item` nil: nothing is highlighted.
    static func willHighlight(_ item: NSMenuItem?, in menu: NSMenu) {
        for candidate in menu.items {
            guard let box = candidate.representedObject as? RowBox else { continue }
            let highlighted = candidate === item
            guard box.highlighted != highlighted else { continue }
            box.highlighted = highlighted
            update(candidate, to: box.row)
        }
    }

    /// The command of an item `build` made, or nil for one that does nothing.
    static func command(of item: NSMenuItem) -> MenuCommand? {
        (item.representedObject as? RowBox)?.row.command
    }

    // MARK: Items

    private static func item(for row: MenuRow, actions: MenuActionTarget) -> NSMenuItem {
        let item: NSMenuItem
        switch row {
        case .separator:
            item = .separator()
        case .progress:
            item = NSMenuItem()
            item.view = ProgressRowView()
        case .submenu(let title, _, let children):
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for child in children { submenu.addItem(self.item(for: child, actions: actions)) }
            item.submenu = submenu
        case .message:
            item = NSMenuItem()
        case .banner, .plan, .button:
            item = NSMenuItem(title: "", action: #selector(MenuActionTarget.menuItemChosen(_:)), keyEquivalent: "")
            item.target = actions
            if case .button(_, let command, _, _) = row { item.keyEquivalent = keyEquivalent(command) }
        }
        update(item, to: row)
        return item
    }

    private static func update(_ item: NSMenuItem, to row: MenuRow) {
        let box: RowBox
        if let existing = item.representedObject as? RowBox {
            box = existing
            box.row = row
        } else {
            box = RowBox(row)
            item.representedObject = box
        }
        let palette = Palette(highlighted: box.highlighted)
        switch row {
        case .separator:
            break
        case .banner(let banner):
            item.title = "\(banner.title). \(banner.detail) \(banner.action.buttonTitle)"
            item.attributedTitle = bannerTitle(banner, palette)
            item.image = bannerImage(banner.severity, palette)
            item.isEnabled = true
        case .plan(let line):
            // The severity's word first for VoiceOver, since the symbol that shows it isn't read as part of the title.
            let status = line.severity.map { "\($0.accessibilityLabel): \(line.status)" } ?? line.status
            item.title = [line.name, status, line.detail, line.destination].compactMap(\.self).joined(separator: ", ")
            item.attributedTitle = planTitle(line, palette)
            item.isEnabled = true
        case .progress(_, let name, let fraction):
            item.isEnabled = false
            (item.view as? ProgressRowView)?.show(fraction, of: name)
        case .message(let text):
            item.title = text
            item.isEnabled = false
        case .button(let title, _, let enabled, let indented):
            item.title = title
            item.isEnabled = enabled
            item.indentationLevel = indented ? 1 : 0
        case .submenu(let title, let enabled, let children):
            item.title = title
            item.isEnabled = enabled
            if let submenu = item.submenu {
                for (child, row) in zip(submenu.items, children) { update(child, to: row) }
            }
        }
    }

    private static func keyEquivalent(_ command: MenuCommand) -> String {
        switch command {
        case .settings: ","
        case .quit: "q"
        default: ""
        }
    }

    // MARK: Text

    private static let titleFont = NSFont.menuFont(ofSize: 0)
    private static let boldFont = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
    private static let smallFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)

    /// The text colours of a row: its own, or all the selected-menu-item text colour while it is highlighted.
    private struct Palette {
        var highlighted: Bool

        func colour(_ own: NSColor) -> NSColor { highlighted ? .selectedMenuItemTextColor : own }
    }

    /// "Full Disk Access is missing" in bold, then the detail and the fix, as the mockup's banners.
    private static func bannerTitle(_ banner: MenuBanner, _ palette: Palette) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: banner.title, attributes: [.font: boldFont, .foregroundColor: palette.colour(.labelColor)])
        let detail = banner.detail.isEmpty ? "" : banner.detail + " "
        text.append(NSAttributedString(
            string: "\n" + detail, attributes: [.font: smallFont, .foregroundColor: palette.colour(.secondaryLabelColor)]))
        text.append(NSAttributedString(
            string: banner.action.buttonTitle,
            attributes: [.font: smallFont, .foregroundColor: palette.colour(.controlAccentColor)]))
        return text
    }

    /// The plan's name, its status in the label colour (grey while paused) after a tinted symbol when it is a warning
    /// or an error, then the detail and the destination in secondary text. The words are never coloured: the symbol's
    /// shape carries the severity, so the line reads the same in either appearance and with Increase Contrast.
    private static func planTitle(_ line: PlanLine, _ palette: Palette) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: line.name, attributes: [.font: boldFont, .foregroundColor: palette.colour(.labelColor)])
        let statusColour: NSColor = line.isPaused && line.severity == nil ? .secondaryLabelColor : .labelColor
        text.append(NSAttributedString(string: "\n", attributes: [.font: titleFont]))
        if let severity = line.severity, let symbol = severitySymbol(severity, palette, pointSize: titleFont.pointSize) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            // Sits on the text's baseline, as tall as a capital letter.
            attachment.bounds = CGRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: [.font: titleFont]))
        }
        text.append(NSAttributedString(
            string: line.status, attributes: [.font: titleFont, .foregroundColor: palette.colour(statusColour)]))
        for secondary in [line.detail, line.destination].compactMap(\.self) where !secondary.isEmpty {
            text.append(NSAttributedString(
                string: "\n" + secondary,
                attributes: [.font: smallFont, .foregroundColor: palette.colour(.secondaryLabelColor)]))
        }
        return text
    }

    /// The severity's symbol (`Severity.symbolName`: a triangle or an octagon), tinted orange or red (coloured, so not
    /// template: inside the menu, unlike the menu bar). While highlighted it is drawn in the selected-menu-item text
    /// colour, which the menu uses on the accent colour.
    private static func severitySymbol(_ severity: Severity, _ palette: Palette, pointSize: CGFloat? = nil) -> NSImage? {
        let tint: NSColor = severity == .error ? .systemRed : .systemOrange
        guard let symbol = NSImage(systemSymbolName: severity.symbolName, accessibilityDescription: severity.accessibilityLabel)
        else { return nil }
        var configuration = NSImage.SymbolConfiguration(paletteColors: [palette.highlighted ? .selectedMenuItemTextColor : tint])
        if let pointSize {
            configuration = configuration.applying(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .small))
        }
        return symbol.withSymbolConfiguration(configuration)
    }

    private static func bannerImage(_ severity: Severity, _ palette: Palette) -> NSImage? {
        severitySymbol(severity, palette)
    }
}

/// The row an item was made from, kept on the item so the next `build` can compare and update it.
@MainActor
private final class RowBox: NSObject {
    var row: MenuRow
    /// Drawn with the highlight's colours (`MenuBuilder.willHighlight`).
    var highlighted = false
    init(_ row: MenuRow) { self.row = row }
}

/// A running backup's progress bar, under its plan's line. A view, so the menu doesn't highlight it.
@MainActor
private final class ProgressRowView: NSView {
    private let bar = NSProgressIndicator()

    /// The bar is the only thing VoiceOver finds in the row, so it says whose backup it is and how far along.
    /// With no fraction restic is still counting the files, so the bar has no end and says so (Task 16e).
    func show(_ fraction: Double?, of planName: String) {
        bar.setAccessibilityLabel("\(planName) backup progress")
        guard let fraction else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            bar.setAccessibilityValueDescription("Checking for changes")
            return
        }
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = fraction
        bar.setAccessibilityValueDescription(fraction.formatted(.percent.precision(.fractionLength(0))))
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 14))
        autoresizingMask = [.width]
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            // Lined up with the item titles: the menu's standard 14 pt inset plus the state column.
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
