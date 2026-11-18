import AppKit

/// The app's main menu. A menu bar (`LSUIElement`) app gets none by default, so without it ⌘C, ⌘V, ⌘X, ⌘A,
/// ⌘Z and ⌘W do nothing in its windows (UI design §8): key equivalents reach the first responder only
/// through a menu item. Every item sends its standard selector to the first responder (`target` nil), so
/// text fields, SwiftUI's included, handle them as in any Mac app.
///
/// While one of its windows is open Restorey is an ordinary app (`WindowActivation`, O1), so this menu is also its
/// menu bar then: the app menu (About, Settings…, Services, Hide, Hide Others, Show All, Quit), Edit, Window and
/// Help, in the order of the HIG's menu bar page. With no window open it is a menu bar app again and shows no menu
/// bar; the status item's menu has Quit. ⌘, lives here, not only on the status item's menu, whose key equivalents
/// work only while that menu is open.
///
/// The entry point is `AppDelegate.main` driving `NSApplication` itself, not SwiftUI's `App`, so no scene
/// replaces this menu after launch.
@MainActor
enum MainMenu {
    /// `settings` opens the Settings window; `canShowSettings` says whether this copy has one (a copy outside
    /// /Applications has none, so the item is dimmed).
    static func install(canShowSettings: @escaping @MainActor () -> Bool, showSettings: @escaping @MainActor () -> Void) {
        MenuActions.shared.canShowSettings = canShowSettings
        MenuActions.shared.openSettings = showSettings
        // One window is one task: no "Show Tab Bar" or "Merge All Windows" in the Window menu (each window also
        // opts out, `WindowRouter.makeWindow`).
        NSWindow.allowsAutomaticWindowTabbing = false
        let app = NSApplication.shared
        let menu = NSMenu()
        let appMenu = appMenu()
        menu.addItem(submenu(appMenu.menu))
        menu.addItem(submenu(editMenu()))
        let window = windowMenu()
        menu.addItem(submenu(window))
        let help = helpMenu()
        menu.addItem(submenu(help))
        app.mainMenu = menu
        app.servicesMenu = appMenu.services
        app.windowsMenu = window
        app.helpMenu = help
    }

    /// The Help menu's one page: the README's "Using Restorey" section, which says what the app does from the user's
    /// side. Restorey has no Help Book, and the repository is public, so the page is the simplest true target.
    static let helpURL = URL(string: "https://github.com/jaydenk/restorey#using-restorey")!

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Restorey"
    }

    private static func appMenu() -> (menu: NSMenu, services: NSMenu) {
        // The title of the first menu is ignored: macOS shows the app's name there.
        let menu = NSMenu(title: appName)
        let about = item("About \(appName)", #selector(MenuActions.showAbout(_:)))
        about.target = MenuActions.shared
        menu.addItem(about)
        menu.addItem(.separator())
        // The HIG's "Settings…" item with ⌘, (HIG Settings).
        let settings = item("Settings…", #selector(MenuActions.showSettings(_:)), ",")
        settings.target = MenuActions.shared
        menu.addItem(settings)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return (menu, services)
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v",
                          [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// Minimise and Zoom for the Full Keyboard Access (HIG Window menu): each dims for a window that doesn't allow it
    /// (Settings has neither, `WindowRouter`). Close is ⌘W.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        let help = item("\(appName) Help", #selector(MenuActions.showHelp(_:)), "?")
        help.target = MenuActions.shared
        menu.addItem(help)
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// The target of the items that aren't a standard responder-chain selector: About, Settings… and Help.
@MainActor
private final class MenuActions: NSObject, NSMenuItemValidation {
    static let shared = MenuActions()
    var canShowSettings: @MainActor () -> Bool = { false }
    var openSettings: @MainActor () -> Void = {}

    /// The standard panel, shown through `WindowActivation` so it counts as one of Restorey's windows while it is up
    /// (review M2).
    @objc func showAbout(_ sender: Any?) {
        WindowActivation.showAbout()
    }

    @objc func showSettings(_ sender: Any?) {
        openSettings()
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(MainMenu.helpURL)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(showSettings(_:)) ? canShowSettings() : true
    }
}
