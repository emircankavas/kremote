import SwiftUI
import AppKit

/// Reports left clicks with the modifier keys that were held.
///
/// A SwiftUI `TapGesture` carries no modifiers, and reading
/// `NSEvent.modifierFlags` inside its action is unreliable: by the time the
/// gesture fires the flags are often already cleared, so ⌘-click and ⇧-click
/// looked like plain clicks and multi-selection never worked.
///
/// The event monitor below sees the real `leftMouseDown`, where the flags are
/// exact, and only acts when the click landed on the view it is attached to.
struct ClickCatcher: NSViewRepresentable {
    /// Called with the click count (2 = double click) and the held modifiers.
    let onClick: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
    }

    final class CatcherView: NSView {
        var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            // Local monitors run before the event is dispatched, so the flags are
            // still the ones the user is holding.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.onClick?(event.clickCount, event.modifierFlags)
                // Consume it: the row draws its own highlight, and letting SwiftUI
                // also see the click would make a double click select twice.
                return nil
            }
        }

        deinit { MainActor.assumeIsolated { removeMonitor() } }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    /// Handles clicks with modifiers, which `TapGesture` cannot report.
    func onClick(_ handler: @escaping (Int, NSEvent.ModifierFlags) -> Void) -> some View {
        overlay(ClickCatcher(onClick: handler))
    }
}
