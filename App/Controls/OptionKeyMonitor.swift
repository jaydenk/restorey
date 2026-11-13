import AppKit
import SwiftUI

/// Reports whether Option is held while the window this view is in is key (Restore Files' "hold Option to
/// show", UI design §5). A local `flagsChanged` monitor sees the key go down and up; becoming key reads the
/// current flags (Option may have been pressed while the Touch ID prompt had the focus), and resigning key
/// reports false, since a window that isn't key hears no more key events. The monitor goes with the view.
struct OptionKeyMonitor: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var held = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                if let self, event.window === self.window { self.report(event.modifierFlags) }
                return event
            }
            let centre = NotificationCenter.default
            observers = [
                centre.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(NSEvent.modifierFlags) }
                },
                centre.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report([]) }
                },
            ]
            if window.isKeyWindow { report(NSEvent.modifierFlags) }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            report([])
        }

        private func report(_ flags: NSEvent.ModifierFlags) {
            let option = flags.intersection(.deviceIndependentFlagsMask).contains(.option) && window?.isKeyWindow == true
            guard option != held else { return }
            held = option
            onChange?(option)
        }
    }
}
