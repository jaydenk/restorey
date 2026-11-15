import AppKit

/// The app's main menu. A menu bar (`LSUIElement`) app gets none by default, so without it ⌘C, ⌘V, ⌘X, ⌘A,
/// ⌘Z and ⌘W do nothing in its windows (UI design §8): key equivalents reach the first responder only
/// through a menu item. Every item sends its standard selector to the first responder (`target` nil), so
/// text fields, SwiftUI's included, handle them as in any Mac app.
///
/// While one of its windows is open Restorey is an ordinary app (`WindowActivation`, O1), so this menu is also its
/// menu bar then: the app menu (About, Hide, Quit), Edit and Window. With no window open it is a menu bar app again
/// and shows no menu bar; the status item's menu has Quit.
///
/// The entry point is `AppDelegate.main` driving `NSApplication` itself, not SwiftUI's `App`, so no scene
/// replaces this menu after launch.
@MainActor
enum MainMenu {
    static func install() {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(editMenu()))
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.windowsMenu = window
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Restorey"
    }

    private static func appMenu() -> NSMenu {
        // The title of the first menu is ignored: macOS shows the app's name there.
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
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

    /// Not in the brief's list, but without Close a Settings or setup window can't be closed with ⌘W.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
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
