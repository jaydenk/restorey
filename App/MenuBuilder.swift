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
        if let box = item.representedObject as? RowBox {
            box.row = row
        } else {
            item.representedObject = RowBox(row)
        }
        switch row {
        case .separator:
            break
        case .banner(let banner):
            item.title = "\(banner.title). \(banner.detail) \(banner.action.buttonTitle)"
            item.attributedTitle = bannerTitle(banner)
            item.image = bannerImage(banner.severity)
            item.isEnabled = true
        case .plan(let line):
            item.title = [line.name, line.status, line.detail, line.destination].compactMap(\.self).joined(separator: ", ")
            item.attributedTitle = planTitle(line)
            item.isEnabled = true
        case .progress(_, let fraction):
            item.isEnabled = false
            (item.view as? ProgressRowView)?.fraction = fraction
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

    /// "Full Disk Access is missing" in bold, then the detail and the fix, as the mockup's banners.
    private static func bannerTitle(_ banner: MenuBanner) -> NSAttributedString {
        let text = NSMutableAttributedString(string: banner.title, attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor])
        let detail = banner.detail.isEmpty ? "" : banner.detail + " "
        text.append(NSAttributedString(
            string: "\n" + detail, attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]))
        text.append(NSAttributedString(
            string: banner.action.buttonTitle, attributes: [.font: smallFont, .foregroundColor: NSColor.controlAccentColor]))
        return text
    }

    /// The plan's name, its status (red for an error, orange for a warning, grey while paused), then the detail and
    /// the destination in secondary text.
    private static func planTitle(_ line: PlanLine) -> NSAttributedString {
        let text = NSMutableAttributedString(string: line.name, attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor])
        let statusColour: NSColor = switch line.severity {
        case .error: .systemRed
        case .warning: .systemOrange
        case nil: line.isPaused ? .secondaryLabelColor : .labelColor
        }
        text.append(NSAttributedString(string: "\n" + line.status, attributes: [.font: titleFont, .foregroundColor: statusColour]))
        for secondary in [line.detail, line.destination].compactMap(\.self) where !secondary.isEmpty {
            text.append(NSAttributedString(
                string: "\n" + secondary, attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    /// Coloured, so not template: red for an error, orange for a warning. Inside the menu, unlike the menu bar.
    private static func bannerImage(_ severity: Severity) -> NSImage? {
        let (name, colour): (String, NSColor) = switch severity {
        case .error: ("exclamationmark.octagon.fill", .systemRed)
        case .warning: ("exclamationmark.triangle", .systemOrange)
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: severity == .error ? "Error" : "Warning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: colour))
    }
}

/// The row an item was made from, kept on the item so the next `build` can compare and update it.
@MainActor
private final class RowBox: NSObject {
    var row: MenuRow
    init(_ row: MenuRow) { self.row = row }
}

/// A running backup's progress bar, under its plan's line. A view, so the menu doesn't highlight it.
@MainActor
private final class ProgressRowView: NSView {
    private let bar = NSProgressIndicator()

    var fraction: Double {
        get { bar.doubleValue }
        set { bar.doubleValue = newValue }
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
