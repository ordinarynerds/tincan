import AppKit
import SwiftUI
import TincanCore

/// One stretch of review mode: an overlay on every window, the note sheet, and the pins of notes
/// already left. Ends when the person presses Escape or the shortcut again.
@MainActor
final class ReviewSession: NSObject {
    let store: NoteStore
    let context: @MainActor () -> [String: String]

    private var overlays: [ObjectIdentifier: Overlay] = [:]
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var timer: Timer?
    private var popover: NSPopover?
    private var running = false

    struct Overlay {
        weak var window: NSWindow?
        var panel: NSPanel
        var view: OverlayView
    }

    static let instructions =
        "Click something, or drag across a region, to leave a note. Hold ⌥ to use the app. Esc to finish."

    init(store: NoteStore, context: @escaping @MainActor () -> [String: String]) {
        self.store = store
        self.context = context
    }

    func start() {
        running = true
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
            let swallow = MainActor.assumeIsolated {
                self?.handle(isFlags: isFlags, option: option, escape: escape) ?? false
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

    private func eligible(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
            && window.level == .normal && window.contentView != nil
    }

    private func attachOverlays() {
        guard running else { return }
        for window in NSApp.windows where eligible(window) && overlays[ObjectIdentifier(window)] == nil {
            let view = OverlayView(frame: CGRect(origin: .zero, size: window.frame.size))
            view.delegate = self
            view.instructions = Self.instructions
            let panel = NSPanel(
                contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = view
            window.addChildWindow(panel, ordered: .above)
            overlays[ObjectIdentifier(window)] = Overlay(window: window, panel: panel, view: view)
        }
        refreshPins()
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

    private func overlay(for view: OverlayView) -> Overlay? {
        overlays.values.first { $0.view === view }
    }

    private func handle(isFlags: Bool, option: Bool, escape: Bool) -> Bool {
        if isFlags {
            let passThrough = option && popover == nil
            for overlay in overlays.values {
                overlay.panel.ignoresMouseEvents = passThrough
                if passThrough { overlay.view.highlight = nil }
            }
            return false
        }
        guard escape, popover == nil else { return false }
        Tincan.stop()
        return true
    }

    // MARK: - Pins

    private func refreshPins() {
        let open = store.notes(status: .open)
        for overlay in overlays.values {
            guard let window = overlay.window else { continue }
            let size = window.frame.size
            overlay.view.pins = open.enumerated().compactMap { index, note in
                guard note.window.title == window.title else { return nil }
                let rect = Geometry.cgRect(note.target.rect)
                let center = CGPoint(
                    x: min(max(rect.maxX, 12), size.width - 12),
                    y: min(max(rect.minY, 12), size.height - 12))
                return OverlayView.Pin(number: index + 1, noteID: note.id, text: note.text, center: center)
            }
            overlay.view.instructions =
                open.isEmpty ? Self.instructions : "\(Self.instructions) \(open.count) open."
        }
    }

    // MARK: - Writing a note

    private func screenPoint(_ point: CGPoint, in overlay: Overlay) -> CGPoint {
        overlay.panel.convertPoint(toScreen: overlay.view.convert(point, to: nil))
    }

    private func compose(on overlay: Overlay, rect: CGRect, target: Note.Target) {
        guard let window = overlay.window, popover == nil else { return }
        overlay.view.pinned = rect
        overlay.view.highlight = nil
        Task {
            let shot = await WindowCapture.capture(window)
            guard running, overlays[ObjectIdentifier(window)] != nil else { return }
            present(on: overlay, window: window, rect: rect, target: target, shot: shot)
        }
    }

    private func present(on overlay: Overlay, window: NSWindow, rect: CGRect, target: Note.Target, shot: WindowCapture.Shot?) {
        let defaults = UserDefaults.standard
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let close: () -> Void = { [weak self, weak popover] in
            popover?.close()
            self?.popover = nil
            overlay.view.pinned = nil
        }
        let composer = Composer(
            title: target.summary, isRegion: target.kind == .region, canAttach: shot != nil,
            attachElement: defaults.object(forKey: "TincanAttachElement") as? Bool ?? true,
            attachWindow: defaults.object(forKey: "TincanAttachWindow") as? Bool ?? true,
            save: { [weak self] draft in
                defaults.set(draft.attachElement, forKey: "TincanAttachElement")
                defaults.set(draft.attachWindow, forKey: "TincanAttachWindow")
                self?.save(draft, window: window, overlay: overlay, rect: rect, target: target, shot: shot)
                close()
            },
            cancel: close)
        popover.contentViewController = NSHostingController(rootView: composer)
        self.popover = popover
        popover.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: overlay.view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func save(
        _ draft: Composer.Draft, window: NSWindow, overlay: Overlay, rect: CGRect,
        target: Note.Target, shot: WindowCapture.Shot?
    ) {
        let info = Bundle.main.infoDictionary ?? [:]
        let note = Note(
            id: NoteStore.makeID(),
            created: Date(),
            text: draft.text,
            app: Note.AppInfo(
                bundleID: Bundle.main.bundleIdentifier,
                name: (info["CFBundleName"] as? String) ?? ProcessInfo.processInfo.processName,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String),
            context: context(),
            window: Note.WindowInfo(
                title: window.title, identifier: window.identifier?.rawValue,
                size: Note.Size(width: window.frame.width, height: window.frame.height),
                scale: Double(shot?.scale ?? window.backingScaleFactor)),
            target: target)
        let element = draft.attachElement ? shot.flatMap { WindowCapture.crop($0, to: rect) }.flatMap(WindowCapture.png) : nil
        let whole = draft.attachWindow ? shot.flatMap { WindowCapture.outlined($0, rect: rect) }.flatMap(WindowCapture.png) : nil
        do {
            let saved = try store.save(note, elementImage: element, windowImage: whole)
            say("Saved note \(saved.id). Run `tincan list` to see it.", on: overlay)
        } catch {
            say("Could not save the note: \(error.localizedDescription)", on: overlay)
        }
        refreshPins()
    }

    private func say(_ message: String, on overlay: Overlay) {
        overlay.view.flash = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if overlay.view.flash == message { overlay.view.flash = nil }
        }
    }
}

extension ReviewSession: OverlayViewDelegate {
    func overlay(_ view: OverlayView, hoverAt point: CGPoint) -> OverlayView.Highlight? {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window,
              let hit = ElementReader.hit(at: screenPoint(point, in: overlay), in: window)
        else { return nil }
        return .init(
            rect: Geometry.windowTopLeft(hit.screenFrame, in: window.frame),
            label: hit.element.summary)
    }

    func overlay(_ view: OverlayView, clickAt point: CGPoint) {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window else { return }
        let screen = screenPoint(point, in: overlay)
        let viewName = ElementReader.viewName(at: screen, in: window)
        if let hit = ElementReader.hit(at: screen, in: window) {
            let rect = Geometry.windowTopLeft(hit.screenFrame, in: window.frame)
            compose(on: overlay, rect: rect, target: Note.Target(
                kind: .element, rect: Geometry.rect(rect), element: hit.element, view: viewName))
        } else {
            let rect = CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)
            compose(on: overlay, rect: rect, target: Note.Target(
                kind: .region, rect: Geometry.rect(rect), view: viewName))
        }
    }

    func overlay(_ view: OverlayView, region rect: CGRect) {
        guard popover == nil, let overlay = overlay(for: view), let window = overlay.window else { return }
        let center = screenPoint(CGPoint(x: rect.midX, y: rect.midY), in: overlay)
        compose(on: overlay, rect: rect, target: Note.Target(
            kind: .region, rect: Geometry.rect(rect), view: ElementReader.viewName(at: center, in: window)))
    }

    func overlay(_ view: OverlayView, menuFor pin: OverlayView.Pin) -> NSMenu? {
        let store = store
        let menu = NSMenu()
        menu.addItem(ActionItem("Copy Note ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pin.noteID, forType: .string)
        })
        menu.addItem(ActionItem("Mark as Resolved") { [weak self] in
            _ = try? store.resolve(pin.noteID, summary: "Resolved in the app")
            self?.refreshPins()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Delete Note") { [weak self] in
            try? store.delete(pin.noteID)
            self?.refreshPins()
        })
        return menu
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
