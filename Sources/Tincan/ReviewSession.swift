import AppKit
import SwiftUI
import TincanCore

/// One stretch of review mode: an overlay on every window, the note sheet, and the pins of notes
/// already left. Ends when the person presses Escape or the shortcut again.
@MainActor
final class ReviewSession: NSObject {
    let store: NoteStore
    let context: @MainActor () -> [String: String]

    var overlays: [ObjectIdentifier: Overlay] = [:]
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var timer: Timer?
    var popover: NSPopover?
    /// The sheet on screen, with the words in it.
    var sheet: Sheet?
    /// Words put aside by cancelling a sheet, by what they were written about, offered again.
    var drafts: [String: String] = [:]
    var lastCancelled: (key: String, text: String)?
    /// Fixes still to step through, while checking fixes.
    var checking: Checking?
    /// A note asked for before the overlays were up, shown as soon as they are.
    var pendingShow: (() -> Void)?
    /// A fix is being photographed before its sheet opens.
    var presenting = false
    /// The context the pins were last placed for. When it changes, earlier searches are stale.
    private var lastContext: [String: String] = [:]
    private let screenText = ScreenText()
    /// How far above the innermost layer the person has stepped with ↑, and which stack that was in.
    private var level = 0
    private var levelAnchor: String?
    var running = false
    private var optionHeld = false
    var usingApp = false { didSet { applyPassThrough() } }

    struct Overlay {
        weak var window: NSWindow?
        var panel: NSPanel
        var view: OverlayView
    }

    static let instructions =
        "Click something, or drag across a region, to leave a note. Click a pin to open its note. ↑ and ↓ choose the parent or child. Hold ⌥ or choose Use App to use the app. Esc or Done to finish."
    /// What the bottom line shrinks to once the instructions have been shown a few times.
    static let hints = "Click or drag to note    ↑ ↓ parent, child    Tab pins    ⌥ use the app    Esc done"
    static let sessionsKey = "TincanReviewSessions"
    /// How many times review mode shows the full instructions before only the hints.
    static let fullInstructionSessions = 3
    static let spotLabel = "No element here. Click to note this spot, or drag around it."
    static let usingAppInstructions = "Clicks reach the app. Choose Leave Notes in the Tincan bar to point at things again."

    /// Clicks go to the app while ⌥ is held or Use App is chosen, but never while a note is open,
    /// since the note sheet belongs to the overlay.
    static func passesThrough(optionHeld: Bool, usingApp: Bool, composing: Bool) -> Bool {
        (optionHeld || usingApp) && !composing
    }

    init(store: NoteStore, context: @escaping @MainActor () -> [String: String]) {
        self.store = store
        self.context = context
    }

    /// Whether the full instructions still show this session, rather than only the hints.
    private var showsFullInstructions = true

    func start() {
        running = true
        let sessions = UserDefaults.standard.integer(forKey: Self.sessionsKey)
        showsFullInstructions = sessions < Self.fullInstructionSessions
        UserDefaults.standard.set(sessions + 1, forKey: Self.sessionsKey)
        Task {
            await ElementReader.wake()
            guard running else { return }
            attachOverlays()
            refreshPins()
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachOverlays() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.follow(window) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.detach(window) }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isFlags = event.type == .flagsChanged
            let option = event.modifierFlags.contains(.option)
            let escape = event.keyCode == 53
            let step = event.keyCode == 126 ? 1 : event.keyCode == 125 ? -1 : 0
            let key = Key(code: event.keyCode, shift: event.modifierFlags.contains(.shift))
            let swallow = MainActor.assumeIsolated {
                self?.handle(isFlags: isFlags, option: option, escape: escape, step: step, key: key) ?? false
            }
            return swallow ? nil : event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPins() }
        }
    }

    func stop() {
        running = false
        popover?.close()
        popover = nil
        sheet = nil
        checking = nil
        pendingShow = nil
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for overlay in overlays.values {
            overlay.window?.removeChildWindow(overlay.panel)
            overlay.panel.orderOut(nil)
        }
        overlays = [:]
    }

    // MARK: - Windows

    static func isReviewable(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isSheet && window.styleMask.contains(.titled) && !(window is NSPanel)
            && window.level == .normal && window.contentView != nil
    }

    private func attachOverlays() {
        guard running else { return }
        for window in NSApp.windows where Self.isReviewable(window) && overlays[ObjectIdentifier(window)] == nil {
            let view = OverlayView(frame: CGRect(origin: .zero, size: window.frame.size))
            view.delegate = self
            view.instructions = Self.instructions
            let panel = NSPanel(
                contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = passingThrough
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = view
            window.addChildWindow(panel, ordered: .above)
            overlays[ObjectIdentifier(window)] = Overlay(window: window, panel: panel, view: view)
        }
        refreshPins()
        if let pending = pendingShow {
            pendingShow = nil
            pending()
        }
    }

    private func follow(_ window: NSWindow?) {
        guard let window, let overlay = overlays[ObjectIdentifier(window)] else { return }
        overlay.panel.setFrame(window.frame, display: true)
        refreshPins()
    }

    private func detach(_ window: NSWindow?) {
        guard let window, let overlay = overlays.removeValue(forKey: ObjectIdentifier(window)) else { return }
        window.removeChildWindow(overlay.panel)
        overlay.panel.orderOut(nil)
    }

    func overlay(for view: OverlayView) -> Overlay? {
        overlays.values.first { $0.view === view }
    }

    private var passingThrough: Bool {
        Self.passesThrough(optionHeld: optionHeld, usingApp: usingApp, composing: popover != nil)
    }

    func applyPassThrough() {
        let pass = passingThrough
        for overlay in overlays.values {
            overlay.panel.ignoresMouseEvents = pass
            if pass { overlay.view.highlight = nil }
        }
        refreshPins()
    }

    struct Key {
        var code: UInt16
        var shift: Bool

        var isTab: Bool { code == 48 }
        var opens: Bool { code == 36 || code == 76 || code == 49 }
    }

    private func handle(isFlags: Bool, option: Bool, escape: Bool, step: Int, key: Key) -> Bool {
        if isFlags {
            optionHeld = option
            applyPassThrough()
            return false
        }
        if popover == nil, !passingThrough, let view = keyOverlay?.view {
            if key.isTab { return view.focusPin(forward: !key.shift) }
            if key.opens, let pin = view.focusedPin {
                overlay(view, open: pin)
                return true
            }
            if escape, view.focusedPinID != nil {
                view.focusedPinID = nil
                view.flash = nil
                return true
            }
        }
        if step != 0 {
            guard popover == nil, !passingThrough, levelAnchor != nil else { return false }
            level = max(0, level + step)
            overlays.values.forEach { $0.view.refreshHover() }
            return true
        }
        guard escape, popover == nil else { return false }
        Tincan.stop()
        return true
    }

    // MARK: - Pins

    /// The overlay on the window the keys go to.
    private var keyOverlay: Overlay? {
        overlays.values.first { $0.window?.isKeyWindow == true } ?? overlays.values.first
    }

    /// Pins for the notes left on each window, here: on this screen of the app by its context, at
    /// where their element is now. Fixes to check are always pinned; other resolved notes only with
    /// Show Resolved Pins.
    func refreshPins() {
        let state = Tincan.state
        let open = state.open
        let context = context()
        if context != lastContext {
            lastContext = context
            Tincan.locator.forget()
        }
        let keys = Tincan.configuration.placeKeys
        let shown = state.notes.filter { note in
            note.status == .open || note.awaitsCheck || Tincan.showsResolved
        }
        for overlay in overlays.values {
            guard let window = overlay.window else { continue }
            let size = window.frame.size
            overlay.view.pins = shown.compactMap { note -> OverlayView.Pin? in
                guard note.window.title == window.title, note.isLeft(in: context, keys: keys) else { return nil }
                let location = Tincan.locator.locate(note, in: window)
                let kind: OverlayView.Pin.Kind
                if note.status == .open {
                    kind = .open(number: (open.firstIndex { $0.id == note.id } ?? 0) + 1)
                } else if note.awaitsCheck {
                    kind = .toCheck(summary: note.resolution?.summary ?? "")
                } else {
                    kind = .resolved(summary: note.resolution?.summary ?? "")
                }
                return OverlayView.Pin(
                    kind: kind, noteID: note.id, text: note.text,
                    center: OverlayView.Pin.center(for: location.rect, in: size), target: location.rect,
                    targetSummary: note.target.summary, placement: location.placement,
                    agent: Self.agent(for: note, listener: state.listener(for: note)))
            }
            overlay.view.instructionsAreHints = !showsFullInstructions && !(usingApp && !optionHeld)
            if usingApp && !optionHeld {
                overlay.view.instructions = Self.usingAppInstructions
            } else if showsFullInstructions {
                overlay.view.instructions = open.isEmpty ? Self.instructions : "\(Self.instructions) \(open.count) open."
            } else {
                overlay.view.instructions = Self.hints
            }
        }
    }

    /// Whether an agent has a note: still waiting for it to listen, or working on it now.
    static func agent(for note: Note, listener: Listener?) -> OverlayView.Pin.Agent? {
        guard note.status == .open, let handoff = note.handoff else { return nil }
        guard handoff.delivered != nil else { return .waiting(handoff.agent) }
        return listener?.state == .working ? .working(handoff.agent) : nil
    }
}

extension ReviewSession {
    func screenPoint(_ point: CGPoint, in overlay: Overlay) -> CGPoint {
        overlay.panel.convertPoint(toScreen: overlay.view.convert(point, to: nil))
    }
}

extension ReviewSession: OverlayViewDelegate {
    /// One thing a click could note: a line of text read from the screen, an element, or a spot.
    struct Layer {
        var rect: CGRect
        var element: Note.Element?
        var summary: String
        var isSpot = false
    }

    /// Everything under the point, innermost first: the line of text, the element the app reports,
    /// then each ancestor with a frame of its own. Empty space starts with a spot, so the containers
    /// around it are still a ↑ away.
    private func layers(at point: CGPoint, overlay: Overlay, window: NSWindow) -> [Layer] {
        let hits = ElementReader.chain(at: screenPoint(point, in: overlay), in: window)
        var layers: [Layer] = []
        if let innermost = hits.first, !Geometry.coversWindow(innermost.screenFrame, windowFrame: window.frame) {
            if let line = textLine(at: point, in: innermost, window: window, view: overlay.view) {
                let element = ScreenText.element(line, in: innermost.element)
                layers.append(Layer(rect: line.rect, element: element, summary: "\(element.summary) in \(innermost.element.summary)"))
            }
        } else {
            layers.append(Layer(
                rect: Geometry.spot(around: point, within: overlay.view.bounds.size), element: nil,
                summary: Self.spotLabel, isSpot: true))
        }
        layers += hits.map { hit in
            Layer(rect: Geometry.windowTopLeft(hit.screenFrame, in: window.frame), element: hit.element, summary: hit.element.summary)
        }
        return layers
    }

    /// The layer the person has chosen at this point. Moving onto a different innermost layer starts
    /// again from the innermost.
    private func chosen(at point: CGPoint, overlay: Overlay, window: NSWindow) -> (layer: Layer, above: Layer?, depth: Int)? {
        let stack = layers(at: point, overlay: overlay, window: window)
        guard let innermost = stack.first else { return nil }
        let anchor = "\(Int(innermost.rect.minX)),\(Int(innermost.rect.minY)),\(Int(innermost.rect.width)),\(Int(innermost.rect.height)) \(innermost.summary)"
        if anchor != levelAnchor {
            levelAnchor = anchor
            level = 0
        }
        level = min(level, stack.count - 1)
        return (stack[level], level + 1 < stack.count ? stack[level + 1] : nil, level)
    }

    func overlay(_ view: OverlayView, hoverAt point: CGPoint) -> OverlayView.Highlight? {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window,
              let choice = chosen(at: point, overlay: overlay, window: window)
        else { return nil }
        return .init(
            rect: choice.layer.rect, label: choice.layer.summary, parent: choice.above?.summary,
            canGoBack: choice.depth > 0, isSpot: choice.layer.isSpot)
    }

    private func textLine(at point: CGPoint, in hit: ElementReader.Hit, window: NSWindow, view: OverlayView) -> ScreenText.Line? {
        guard ScreenText.reads(inside: hit, window: window) else { return nil }
        let rect = Geometry.windowTopLeft(hit.screenFrame, in: window.frame)
        let lines = screenText.lines(in: rect, of: window) { [weak view] in view?.refreshHover() }
        return lines.flatMap { ScreenText.line(at: point, in: $0) }
    }

    func overlay(_ view: OverlayView, clickAt point: CGPoint) {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window,
              let layer = chosen(at: point, overlay: overlay, window: window)?.layer
        else { return }
        let viewName = ElementReader.viewName(at: screenPoint(point, in: overlay), in: window)
        compose(on: overlay, rect: layer.rect, target: Note.Target(
            kind: layer.element == nil ? .region : .element, rect: Geometry.rect(layer.rect),
            element: layer.element, view: viewName))
    }

    func overlay(_ view: OverlayView, region rect: CGRect) {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window else { return }
        let center = screenPoint(CGPoint(x: rect.midX, y: rect.midY), in: overlay)
        compose(on: overlay, rect: rect, target: Note.Target(
            kind: .region, rect: Geometry.rect(rect), view: ElementReader.viewName(at: center, in: window)))
    }
}

@MainActor
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ActionItem is created in code only")
    }

    @objc private func run() { handler() }
}
