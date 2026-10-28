import AppKit

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlay(_ view: OverlayView, hoverAt point: CGPoint) -> OverlayView.Highlight?
    func overlay(_ view: OverlayView, clickAt point: CGPoint)
    func overlay(_ view: OverlayView, region rect: CGRect)
    func overlay(_ view: OverlayView, open pin: OverlayView.Pin)
    func overlay(_ view: OverlayView, menuFor pin: OverlayView.Pin) -> NSMenu?
    /// A click landed on the overlay while a note's sheet is open.
    func overlayClickedOutsideSheet(_ view: OverlayView)
    var isSheetOpen: Bool { get }
}

/// Draws over one window: the element under the pointer, a region being dragged, the pins of notes
/// already left, and a line saying what to do. Flipped, so its coordinates are the window's own
/// top-left points — the same numbers a note records.
@MainActor
final class OverlayView: NSView {
    struct Highlight: Equatable {
        var rect: CGRect
        /// The layer under the pointer, in a person's words.
        var label: String
        /// The layer ↑ would choose, when there is one.
        var parent: String?
        /// Whether ↓ steps back towards the innermost layer.
        var canGoBack = false
        /// No element is here, so the rect is the spot a click would note, drawn dashed.
        var isSpot = false
    }

    weak var delegate: OverlayViewDelegate?
    var highlight: Highlight? { didSet { if highlight != oldValue { needsDisplay = true } } }
    var pinned: CGRect? { didSet { needsDisplay = true } }
    var pins: [Pin] = [] {
        didSet {
            guard pins != oldValue else { return }
            if let focused = focusedPinID, !pins.contains(where: { $0.noteID == focused }) { focusedPinID = nil }
            needsDisplay = true
            updateRings()
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }
    var instructions = "" { didSet { needsDisplay = true } }
    /// Whether the instructions are the full sentence, or only a line of key hints.
    var instructionsAreHints = false { didSet { needsDisplay = true } }
    var flash: String? { didSet { needsDisplay = true } }
    /// The pin chosen with Tab, drawn with a focus ring and opened with Return.
    var focusedPinID: String? { didSet { if focusedPinID != oldValue { needsDisplay = true } } }

    var dragStart: CGPoint?
    var dragRect: CGRect?
    var hoveredPin: Pin?
    private var hoverPoint: CGPoint?
    var ringLayers: [String: CAShapeLayer] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("OverlayView is created in code only")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        hoveredPin = pin(at: point)
        (hoveredPin == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        highlight = hoveredPin == nil ? delegate?.overlay(self, hoverAt: point) : nil
        needsDisplay = true
    }

    /// Asks again what is under the pointer, after something it depends on has finished arriving.
    func refreshHover() {
        guard let point = hoverPoint, hoveredPin == nil, dragRect == nil else { return }
        highlight = delegate?.overlay(self, hoverAt: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        highlight = nil
        hoveredPin = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if delegate?.isSheetOpen == true {
            delegate?.overlayClickedOutsideSheet(self)
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
        guard rect.width > 4 || rect.height > 4 else { return }
        dragRect = rect
        highlight = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        defer {
            dragStart = nil
            dragRect = nil
            needsDisplay = true
        }
        if let rect = dragRect {
            delegate?.overlay(self, region: rect)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let pin = pin(at: point) {
            delegate?.overlay(self, open: pin)
            return
        }
        delegate?.overlay(self, clickAt: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pin = pin(at: point), let menu = delegate?.overlay(self, menuFor: pin) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func pin(at point: CGPoint) -> Pin? {
        pins.last { hypot($0.center.x - point.x, $0.center.y - point.y) <= Self.pinRadius + 2 }
    }

    static let pinRadius: CGFloat = 10

    // MARK: - Pins from the keyboard

    /// Moves the focus to the next pin, or the previous one, in reading order. Answers whether there
    /// was a pin to move to.
    func focusPin(forward: Bool) -> Bool {
        let ordered = pins.sorted { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }
        guard !ordered.isEmpty else { return false }
        let index = ordered.firstIndex { $0.noteID == focusedPinID }
        let next: Int
        if let index {
            next = (index + (forward ? 1 : -1) + ordered.count) % ordered.count
        } else {
            next = forward ? 0 : ordered.count - 1
        }
        focusedPinID = ordered[next].noteID
        flash = ordered[next].banner
        return true
    }

    var focusedPin: Pin? { pins.first { $0.noteID == focusedPinID } }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        let radius = Self.pinRadius
        return pins.map { pin in
            let box = CGRect(x: pin.center.x - radius, y: pin.center.y - radius, width: radius * 2, height: radius * 2)
            let frame = window.map { $0.convertToScreen(convert(box, to: nil)) } ?? .zero
            return PinElement(noteID: pin.noteID, label: pin.banner, frame: frame, view: self)
        }
    }

    /// Opens the pin's note, for VoiceOver's press.
    func openPin(id: String) -> Bool {
        guard let pin = pins.first(where: { $0.noteID == id }) else { return false }
        delegate?.overlay(self, open: pin)
        return true
    }

    /// A pin as VoiceOver sees it: a button named by what the bottom line says on hover.
    final class PinElement: NSAccessibilityElement {
        let noteID: String
        nonisolated(unsafe) weak var view: OverlayView?

        init(noteID: String, label: String, frame: CGRect, view: OverlayView) {
            self.noteID = noteID
            self.view = view
            super.init()
            setAccessibilityRole(.button)
            setAccessibilityLabel(label)
            setAccessibilityParent(view)
            setAccessibilityFrame(frame)
        }

        override func accessibilityPerformPress() -> Bool {
            let id = noteID
            nonisolated(unsafe) let view = view
            return MainActor.assumeIsolated { view?.openPin(id: id) ?? false }
        }
    }
}
