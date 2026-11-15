import AppKit

extension NSOpenPanel {
    /// Shows the panel as a sheet on the window that asked (the key window: the one whose button was pressed), so
    /// that window can't be closed while the panel is up and Restorey's activation policy, which counts only its own
    /// windows, stays right (review M2). With no key window, it falls back to a panel of its own.
    @MainActor
    func presentForKeyWindow() async -> NSApplication.ModalResponse {
        if let window = NSApplication.shared.keyWindow {
            return await beginSheetModal(for: window)
        }
        return await begin()
    }
}
