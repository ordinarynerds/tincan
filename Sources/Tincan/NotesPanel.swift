import AppKit
import SwiftUI
import TincanCore

/// The notes list in a popover, from the floating bar or the menu bar switch. One at a time: asking
/// again while it shows closes it.
@MainActor
enum NotesPanel {
    private static var popover: NSPopover?

    static func toggle(relativeTo rect: CGRect, of view: NSView, edge: NSRectEdge) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        guard let store = Tincan.store else { return }
        Tincan.refreshNotes()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hosting = NSHostingController(rootView: NotesList(state: Tincan.state, store: store) { close() })
        popover.contentViewController = hosting
        popover.contentSize = settledSize(of: hosting.view)
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// The list measures its rows in a first layout and takes their height in the next, so the
    /// popover is sized after both. Shown at a size it then changes, it would slide off its anchor.
    static func settledSize(of view: NSView) -> CGSize {
        var size = view.fittingSize
        for _ in 0..<3 {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            let next = view.fittingSize
            if next == size { break }
            size = next
        }
        return size
    }

    static func close() {
        popover?.close()
        popover = nil
    }
}
