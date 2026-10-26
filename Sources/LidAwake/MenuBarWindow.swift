import AppKit

/// The window under the menu bar icon.
@MainActor
enum MenuBarWindow {
    /// Closes the window by clicking the app's own menu bar icon, as a person would. The menu bar
    /// extra then hides the window itself and knows it is closed, so the next click on the icon
    /// opens it again. Closing the window directly would leave the extra thinking it is open.
    /// `window` is the open menu bar window; it is closed directly only if the icon is not found.
    static func close(_ window: NSWindow) {
        guard window.isVisible else { return }
        if let button = statusButton() {
            button.performClick(nil)
        } else {
            window.close()
        }
    }

    static func isStatusClick(_ event: NSEvent) -> Bool {
        guard let button = statusButton(), event.window === button.window else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    static func show() {
        guard let button = statusButton() else { return }
        // Clicking again would hide an already-open panel.
        let panelIsVisible = NSApp.windows.contains {
            $0.isVisible && $0 !== button.window && $0.className.contains("MenuBarExtra")
        }
        if !panelIsVisible { button.performClick(nil) }
    }

    /// The app has one menu bar icon.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = firstStatusButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = firstStatusButton(in: subview) {
                return button
            }
        }
        return nil
    }
}
