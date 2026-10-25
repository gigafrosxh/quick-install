import AppKit
import SwiftUI

/// Keeps SwiftUI windows alive and runs cleanup (e.g. ejecting an image) when one closes.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private struct Entry {
        let window: NSWindow
        let key: String?
        let onClose: (() -> Void)?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Shows a window. With a `key`, an already open window for that key is brought to front instead.
    @discardableResult
    func show<Content: View>(
        _ content: Content, title: String, size: NSSize, key: String? = nil, onClose: (() -> Void)? = nil
    ) -> NSWindow {
        if let key, let existing = entries.values.first(where: { $0.key == key })?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.delegate = self
        window.center()
        // Cascade windows for several files opened at once.
        if let front = NSApp.windows.last(where: { $0.isVisible && $0 !== window }) {
            window.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 24, y: front.frame.maxY - 24))
        }

        entries[ObjectIdentifier(window)] = Entry(window: window, key: key, onClose: onClose)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = entries.removeValue(forKey: ObjectIdentifier(window))
        else { return }
        entry.onClose?()
    }
}
