import AppKit
import SwiftUI

/// Gives the Settings window the one-row toolbar System Settings has:
/// back/forward, then the page title on the left. A Settings scene otherwise
/// uses the preferences style, which centres the title and puts toolbar
/// items on a second row underneath. SwiftUI's scene-level toolbar style is
/// ignored for Settings, so this sets it on the window itself.
struct UnifiedToolbarWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowWatcher)?.apply()
    }

    private final class WindowWatcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if window.titleVisibility != .visible { window.titleVisibility = .visible }
        }
    }
}
