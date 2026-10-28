import AppKit

/// How the overlay draws: the outline, the tag naming what is under the pointer, the pins, and the
/// bottom line.
extension OverlayView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = Style.accent
        if let rect = pinned ?? dragRect ?? highlight?.rect {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            let isSpot = pinned == nil && dragRect == nil && highlight?.isSpot == true
            accent.withAlphaComponent(isSpot ? 0.06 : 0.12).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            if isSpot { path.setLineDash([5, 3], count: 2, phase: 0) }
            path.stroke()
        }
        if let hoveredPin, pinned == nil, dragRect == nil {
            let path = NSBezierPath(roundedRect: hoveredPin.target.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            Self.color(for: hoveredPin).withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }
        if pinned == nil, dragRect == nil, let highlight {
            drawTag(highlight)
        }
        for pin in pins { drawPin(pin) }
        if let hoveredPin {
            drawBanner(hoveredPin.banner, quiet: false)
        } else if let flash {
            drawBanner(flash, quiet: false)
        } else {
            drawBanner(instructions, quiet: instructionsAreHints)
        }
    }

    static func color(for pin: Pin) -> NSColor {
        switch pin.kind {
        case .open: Style.accent
        case .toCheck: .systemGreen
        case .resolved: .systemGray
        }
    }

    private func drawPin(_ pin: Pin) {
        let radius = Self.pinRadius
        let box = CGRect(x: pin.center.x - radius, y: pin.center.y - radius, width: radius * 2, height: radius * 2)
        let color = Self.color(for: pin)
        let circle = NSBezierPath(ovalIn: box)
        let missing = pin.placement == .missing
        if pin.noteID == focusedPinID {
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: -4, dy: -4))
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.lineWidth = 3
            ring.stroke()
        }
        if case .waiting = pin.agent {
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: -4, dy: -4))
            color.setStroke()
            ring.lineWidth = 1.5
            ring.setLineDash([3, 3], count: 2, phase: 0)
            ring.stroke()
        }
        (missing ? NSColor.white.withAlphaComponent(0.92) : color).setFill()
        circle.fill()
        (missing ? color : .white).setStroke()
        circle.lineWidth = hoveredPin?.noteID == pin.noteID ? 2.5 : 1.5
        if missing { circle.setLineDash([3, 2], count: 2, phase: 0) }
        circle.stroke()
        let ink = missing ? color : .white
        if let number = pin.number {
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: ink,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: pin.center.x - size.width / 2, y: pin.center.y - size.height / 2))
        } else if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .heavy).applying(.init(paletteColors: [ink]))) {
            let size = check.size
            check.draw(
                in: CGRect(x: pin.center.x - size.width / 2, y: pin.center.y - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The tag over the outline: what is under the pointer in bold, then where ↑ and ↓ lead, quieter.
    private func drawTag(_ highlight: Highlight) {
        let text = NSMutableAttributedString(string: highlight.label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        if let parent = highlight.parent {
            text.append(NSAttributedString(string: "   ↑ \(parent.prefix(48))", attributes: quiet))
        }
        if highlight.canGoBack {
            text.append(NSAttributedString(string: "   ↓ back", attributes: quiet))
        }
        let size = text.size()
        let width = min(size.width + 12, bounds.width - 8)
        let rect = highlight.rect
        var origin = CGPoint(x: rect.minX - 2, y: rect.minY - size.height - 8)
        if origin.y < 2 { origin.y = rect.maxY + 4 }
        origin.x = min(max(2, origin.x), bounds.width - width - 2)
        let box = CGRect(x: origin.x, y: origin.y, width: width, height: size.height + 4)
        Style.accent.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(with: box.insetBy(dx: 6, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The bottom line. Quiet is the short line of key hints shown once the full instructions have
    /// been read a few times: smaller, fainter, out of the way of the app.
    private func drawBanner(_ message: String, quiet: Bool) {
        guard !message.isEmpty else { return }
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: quiet ? 11 : 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(quiet ? 0.85 : 1),
        ])
        let maxWidth = bounds.width - 40
        let size = text.boundingRect(
            with: CGSize(width: maxWidth - 28, height: 60), options: [.usesLineFragmentOrigin]
        ).size
        let padding: CGFloat = quiet ? 10 : 14
        let box = CGRect(
            x: (bounds.width - size.width - padding * 2) / 2, y: bounds.height - size.height - (quiet ? 18 : 34),
            width: size.width + padding * 2, height: size.height + (quiet ? 8 : 14))
        NSColor.black.withAlphaComponent(quiet ? 0.5 : 0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(with: box.insetBy(dx: padding, dy: quiet ? 4 : 7), options: [.usesLineFragmentOrigin])
    }

    /// A ring that keeps widening from a pin while an agent works on its note: the line is live.
    /// With Reduce Motion it is a still ring.
    func updateRings() {
        guard let layer else { return }
        let working = Dictionary(uniqueKeysWithValues: pins.compactMap { pin -> (String, Pin)? in
            guard case .working = pin.agent else { return nil }
            return (pin.noteID, pin)
        })
        for (id, ring) in ringLayers where working[id] == nil {
            ring.removeFromSuperlayer()
            ringLayers[id] = nil
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let side = Self.pinRadius * 2 + 8
        for (id, pin) in working {
            let ring = ringLayers[id] ?? {
                let ring = CAShapeLayer()
                ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
                ring.fillColor = nil
                ring.strokeColor = Self.color(for: pin).cgColor
                ring.lineWidth = 2
                layer.addSublayer(ring)
                ringLayers[id] = ring
                if !reduceMotion {
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = 0.9
                    grow.toValue = 1.7
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.9
                    fade.toValue = 0
                    let group = CAAnimationGroup()
                    group.animations = [grow, fade]
                    group.duration = 1.6
                    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    group.repeatCount = .infinity
                    ring.add(group, forKey: "listening")
                }
                return ring
            }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.position = pin.center
            CATransaction.commit()
        }
    }
}
