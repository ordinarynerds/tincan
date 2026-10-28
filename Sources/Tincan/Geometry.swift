import CoreGraphics
import TincanCore

/// Conversions between the three spaces Tincan touches: AppKit's screen space (origin bottom left,
/// shared by every display), a window measured from its top left in points, and image pixels.
enum Geometry {
    /// A screen rect as points from the window's top-left corner, which is how notes record it.
    static func windowTopLeft(_ screenRect: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: screenRect.minX - windowFrame.minX,
            y: windowFrame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height)
    }

    /// The pixel rect to cut from a window image: the target plus a margin, kept inside the image.
    static func cropRect(
        _ rect: CGRect, margin: CGFloat, scale: CGFloat, imageSize: CGSize
    ) -> CGRect? {
        let padded = rect.insetBy(dx: -margin, dy: -margin)
        let pixels = CGRect(
            x: (padded.minX * scale).rounded(.down),
            y: (padded.minY * scale).rounded(.down),
            width: (padded.width * scale).rounded(.up),
            height: (padded.height * scale).rounded(.up))
        let clamped = pixels.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped.integral
    }

    /// True when an element is really the window's background: a hit on it says nothing about what
    /// the person pointed at, so Tincan treats the click as a point in a region instead.
    static func coversWindow(_ elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let overlap = elementFrame.intersection(windowFrame)
        guard !overlap.isNull, windowFrame.width > 0, windowFrame.height > 0 else { return false }
        return (overlap.width * overlap.height) / (windowFrame.width * windowFrame.height) > 0.6
    }

    /// The square a click notes when nothing accessible is under it, kept inside the window.
    static func spot(around point: CGPoint, side: CGFloat = 48, within size: CGSize) -> CGRect {
        let side = min(side, size.width, size.height)
        return CGRect(
            x: min(max(point.x - side / 2, 0), size.width - side),
            y: min(max(point.y - side / 2, 0), size.height - side),
            width: side, height: side)
    }

    static func rect(_ rect: CGRect) -> Note.Rect {
        Note.Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    static func cgRect(_ rect: Note.Rect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
