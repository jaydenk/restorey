import AppKit
import RestoreyCore

/// Receives every chosen menu item. `MenuBuilder.command(of:)` says what it asks for.
@MainActor
@objc protocol MenuActionTarget: AnyObject {
    func menuItemChosen(_ sender: NSMenuItem)
}

/// Turns `MenuLayout`'s rows into the status item's `NSMenuItem`s. Which rows there are, what they say and what they
/// do is decided in `MenuLayout` (tested in RestoreyCore); this only makes standard items of them (Task 17d, audit
/// P4): section headers (`NSMenuItem.sectionHeader(title:)`, macOS 14), a title with a `subtitle` (macOS 14.4), a
/// symbol image, a tooltip, and separators. AppKit draws them, highlight included, so the menu reads as the system's.
///
/// It can be called while the menu is open: when `MenuLayout.canUpdateInPlace` allows, the existing items are
/// updated where they are, so progress moves under the pointer without losing its highlight or an open submenu;
/// otherwise the items are replaced, which AppKit shows at once in an open menu.
@MainActor
enum MenuBuilder {
    static func build(
        _ content: MenuContent, into menu: NSMenu, actions: MenuActionTarget, developer: Bool,
        diagnostics: MenuDiagnostics? = nil
    ) {
        build(MenuLayout.rows(content, developer: developer, diagnostics: diagnostics), into: menu, actions: actions)
    }

    static func build(_ rows: [MenuRow], into menu: NSMenu, actions: MenuActionTarget) {
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
        case .header(let title):
            item = .sectionHeader(title: title)
        case .progress:
            item = NSMenuItem()
            item.view = ProgressRowView()
        case .submenu(let title, let children):
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for child in children { submenu.addItem(self.item(for: child, actions: actions)) }
            item.submenu = submenu
        case .item(let content):
            item = NSMenuItem(
                title: content.title, action: content.command == nil ? nil : #selector(MenuActionTarget.menuItemChosen(_:)),
                keyEquivalent: content.keyEquivalent)
            if content.command != nil { item.target = actions }
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
        case .header(let title):
            item.title = title
        case .progress(_, let name, let fraction):
            item.isEnabled = false
            (item.view as? ProgressRowView)?.show(fraction, of: name)
        case .submenu(let title, let children):
            // Always enabled, so its items can be seen even when none can be chosen (HIG Menus; audit P2).
            item.title = title
            item.isEnabled = true
            if let submenu = item.submenu {
                for (child, row) in zip(submenu.items, children) { update(child, to: row) }
            }
        case .item(let content):
            item.title = content.title
            // A line (`MenuItem.line`: the diagnostics lines and the message line) is disabled so it can't be chosen, but
            // AppKit would grey it. It is drawn in the secondary label colour at the menu font, so it reads clearly.
            // Setting `attributedTitle` replaces the plain title, so every other item clears it.
            item.attributedTitle = content.isLine ? Self.lineTitle(content.title) : nil
            item.subtitle = content.subtitle
            item.toolTip = content.toolTip
            item.isEnabled = content.enabled
            item.image = content.symbol.flatMap(image)
            // macOS 27 hides menu item images unless asked (`NSMenuItem.image`: "AppKit determines the visibility of
            // menu item images, and will typically hide images"). These carry a plan's state, so they always show.
            item.preferredImageVisibility = content.symbol == nil ? .automatic : .visible
            item.setAccessibilityLabel(content.accessibilityLabel)
        }
    }

    private static func lineTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0),
        ])
    }

    // MARK: Symbols

    /// A severity symbol in its multicolour rendering (the system's yellow triangle and red octagon, each with its
    /// mark in white or black), which keeps its colours and stays legible on the highlight. The other symbols are
    /// template images, which AppKit draws in the item's text colour, the highlighted one included.
    private static func image(_ symbol: MenuSymbol) -> NSImage? {
        if let cached = images[symbol] { return cached }
        guard let image = NSImage(
            systemSymbolName: symbol.symbolName, accessibilityDescription: symbol.severity?.accessibilityLabel)
        else { return nil }
        let made: NSImage
        if symbol.severity != nil {
            made = image.withSymbolConfiguration(.preferringMulticolor()) ?? image
            made.isTemplate = false
        } else {
            made = image
            made.isTemplate = true
        }
        images[symbol] = made
        return made
    }

    private static var images: [MenuSymbol: NSImage] = [:]
}

/// The row an item was made from, kept on the item so the next `build` can compare and update it.
@MainActor
private final class RowBox: NSObject {
    var row: MenuRow
    init(_ row: MenuRow) { self.row = row }
}

/// A running backup's progress bar, under its plan's status: the one row a standard item can't show. It is a view,
/// in a disabled item, so the menu never highlights it or stops on it with the arrow keys, and has nothing to recolour
/// for a highlight; AppKit sizes it to the menu's width. Like the sliders in the system's Sound and Display menus, the
/// bar runs across the menu's content width, from the inset the section headers and symbols start at.
@MainActor
final class ProgressRowView: NSView {
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
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 16))
        autoresizingMask = [.width]
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// The menu's horizontal content inset, which a view item has to keep itself: where the section headers and item
    /// symbols start. No `NSMenu` metric exists for it, so the value is a measurement, not a derivation; 14 matches
    /// the rendered menu on macOS 27 (visual polish spec §5), and the live look checks it again.
    static let inset: CGFloat = 14

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
