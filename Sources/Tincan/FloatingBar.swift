import AppKit
import SwiftUI
import TincanCore

/// A small bar floating above the app that does what the keys do: start and stop review mode, switch
/// between leaving notes and using the app, and reach the notes already left.
///
/// It is a panel of its own, never a child of the app's windows, so it is never in a screenshot and
/// review mode never puts an overlay on it. It hides while the app is in the background.
@MainActor
final class FloatingBar {
    static let originKey = "TincanFloatingBarOrigin"
    static let hiddenKey = "TincanFloatingBarHidden"

    private let panel: BarPanel
    private let hosting: BarHostingView<BarView>
    private let store: NoteStore
    private let shortcut: Tincan.Shortcut?
    private var observers: [NSObjectProtocol] = []

    init(store: NoteStore, shortcut: Tincan.Shortcut?) {
        self.store = store
        self.shortcut = shortcut
        hosting = BarHostingView(rootView: BarView(state: Tincan.state, shortcut: shortcut))
        panel = BarPanel(
            contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.setAccessibilityLabel("Tincan")
        restorePosition()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showIfWanted() }
        })
        showIfWanted()
    }

    func remove() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel.orderOut(nil)
    }

    var isShown: Bool { !UserDefaults.standard.bool(forKey: Self.hiddenKey) }

    func setShown(_ shown: Bool) {
        UserDefaults.standard.set(!shown, forKey: Self.hiddenKey)
        shown ? showIfWanted() : panel.orderOut(nil)
    }

    private func showIfWanted() {
        guard isShown, NSApp.isActive else { return }
        fit()
        panel.orderFront(nil)
    }

    /// Follows the controls' size after a state change, keeping the bar's centre where the person put it.
    func fit() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let size = hosting.fittingSize
            let frame = panel.frame
            guard size != frame.size else { return }
            panel.setFrame(
                CGRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY, width: size.width, height: size.height),
                display: true)
            panel.invalidateShadow()
        }
    }

    /// Opens the notes list below the bar, or above it when the bar sits low on the screen.
    func showNotes() {
        let low = panel.frame.minY < (panel.screen?.visibleFrame.midY ?? 0)
        NotesPanel.toggle(relativeTo: hosting.bounds, of: hosting, edge: low ? .maxY : .minY)
    }

    private func restorePosition() {
        let size = panel.frame.size
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            if Self.isOnScreen(CGRect(origin: origin, size: size), screens: screens) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(Self.defaultOrigin(size: size, visibleFrame: visible))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    /// Centred just below the menu bar, clear of the Dock and of the instructions review mode shows
    /// along the bottom of each window.
    static func defaultOrigin(size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: (visibleFrame.midX - size.width / 2).rounded(), y: visibleFrame.maxY - size.height - 12)
    }

    /// A saved position counts only if the whole bar is still on a screen, so unplugging a display
    /// never leaves it somewhere nobody can reach.
    static func isOnScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { $0.insetBy(dx: -1, dy: -1).contains(frame) }
    }
}

/// Never key and never main, so clicking the bar leaves the app's own window focused.
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, so a control works without first bringing the bar forward.
final class BarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
