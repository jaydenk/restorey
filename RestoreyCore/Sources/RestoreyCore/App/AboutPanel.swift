import Foundation

/// What `AboutPanel` needs to know of a window.
public struct WindowSnapshot: Sendable, Equatable {
    public var number: Int
    public var identifier: String?
    public var isVisible: Bool

    public init(number: Int, identifier: String?, isVisible: Bool) {
        self.number = number
        self.identifier = identifier
        self.isVisible = isVisible
    }
}

/// Picks out the standard About panel once AppKit has shown it, so Restorey counts it as one of its windows until it
/// closes (Task 14c; build 816 finding). The panel is the window that is on screen after the call and wasn't before,
/// other than Restorey's own (`ownIdentifiers`). AppKit gives the panel an identifier of its own ("_NS:149" on
/// macOS 27.2), so "has no identifier", the round-2 rule, never matched it, and the panel went uncounted.
public enum AboutPanel {
    public static func find(before: [WindowSnapshot], after: [WindowSnapshot], ownIdentifiers: Set<String>) -> Int? {
        let wasVisible = Set(before.filter(\.isVisible).map(\.number))
        return after.first { window in
            window.isVisible && !wasVisible.contains(window.number)
                && !(window.identifier.map(ownIdentifiers.contains) ?? false)
        }?.number
    }
}
