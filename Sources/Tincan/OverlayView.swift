import AppKit

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlay(_ view: OverlayView, hoverAt point: CGPoint) -> OverlayView.Highlight?
    func overlay(_ view: OverlayView, clickAt point: CGPoint)
    func overlay(_ view: OverlayView, region rect: CGRect)
    func overlay(_ view: OverlayView, menuFor pin: OverlayView.Pin) -> NSMenu?
}

/// Draws over one window: the element under the pointer, a region being dragged, the pins of notes
/// already left, and a line saying what to do. Flipped, so its coordinates are the window's own
/// top-left points — the same numbers a note records.
@MainActor
final class OverlayView: NSView {
    struct Highlight: Equatable {
        var rect: CGRect
        var label: String
    }

    struct Pin: Equatable {
        var number: Int
        var noteID: String
        var text: String
        var center: CGPoint
    }

    weak var delegate: OverlayViewDelegate?
    var highlight: Highlight? { didSet { if highlight != oldValue { needsDisplay = true } } }
    var pinned: CGRect? { didSet { needsDisplay = true } }
    var pins: [Pin] = [] { didSet { if pins != oldValue { needsDisplay = true } } }
    var instructions = "" { didSet { needsDisplay = true } }
    var flash: String? { didSet { needsDisplay = true } }

    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var hoveredPin: Pin?

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
        hoveredPin = pin(at: point)
        highlight = hoveredPin == nil ? delegate?.overlay(self, hoverAt: point) : nil
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        highlight = nil
        hoveredPin = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
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
        if let pin = pin(at: point), let menu = delegate?.overlay(self, menuFor: pin) {
            menu.popUp(positioning: nil, at: point, in: self)
            return
        }
        delegate?.overlay(self, clickAt: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pin = pin(at: point), let menu = delegate?.overlay(self, menuFor: pin) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func pin(at point: CGPoint) -> Pin? {
        pins.last { hypot($0.center.x - point.x, $0.center.y - point.y) <= Self.pinRadius + 2 }
    }

    static let pinRadius: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        let accent = Style.accent
        if let rect = pinned ?? dragRect ?? highlight?.rect {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            accent.withAlphaComponent(0.12).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        if pinned == nil, dragRect == nil, let highlight {
            drawTag(highlight.label, near: highlight.rect)
        }
        for pin in pins { drawPin(pin) }
        let message = hoveredPin.map { "Note \($0.number): \($0.text)" } ?? flash ?? instructions
        drawBanner(message)
    }

    private func drawPin(_ pin: Pin) {
        let radius = Self.pinRadius
        let circle = NSBezierPath(ovalIn: CGRect(
            x: pin.center.x - radius, y: pin.center.y - radius, width: radius * 2, height: radius * 2))
        Style.accent.setFill()
        circle.fill()
        NSColor.white.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let text = NSAttributedString(string: "\(pin.number)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: pin.center.x - size.width / 2, y: pin.center.y - size.height / 2))
    }

    private func drawTag(_ label: String, near rect: CGRect) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let width = min(size.width + 12, bounds.width - 8)
        var origin = CGPoint(x: rect.minX - 2, y: rect.minY - size.height - 8)
        if origin.y < 2 { origin.y = rect.maxY + 4 }
        origin.x = min(max(2, origin.x), bounds.width - width - 2)
        let box = CGRect(x: origin.x, y: origin.y, width: width, height: size.height + 4)
        Style.accent.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(with: box.insetBy(dx: 6, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawBanner(_ message: String) {
        guard !message.isEmpty else { return }
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let maxWidth = bounds.width - 40
        let size = text.boundingRect(
            with: CGSize(width: maxWidth - 28, height: 60), options: [.usesLineFragmentOrigin]
        ).size
        let box = CGRect(
            x: (bounds.width - size.width - 28) / 2, y: bounds.height - size.height - 34,
            width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(with: box.insetBy(dx: 14, dy: 7), options: [.usesLineFragmentOrigin])
    }
}
