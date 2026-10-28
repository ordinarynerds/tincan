import AppKit
import TincanCore
import Vision

/// The lines of text drawn inside one element, read from the window's pixels.
///
/// An app may expose a whole row as one element, a button whose label is every word in the row. That
/// is often right for VoiceOver, one stop per row, and it leaves nothing smaller in the accessibility
/// tree to point at. The words are still on screen, so Tincan reads them there: the note then names
/// the line the person pointed at, inside the element the app reports, and says the text was read
/// from the screen, since recognition can misread a character the app itself would not.
@MainActor
final class ScreenText {
    struct Line: Equatable {
        var text: String
        /// Window points from the top left.
        var rect: CGRect
    }

    private struct Key: Hashable {
        var window: Int
        var rect: [Int]
    }

    static let freshFor: TimeInterval = 2
    static let roleDescription = "text read from the screen"

    private var read: [Key: (at: Date, lines: [Line])] = [:]
    private var reading: Set<Key> = []

    /// The element's lines, or nil while they are being read for the first time. `ready` runs when
    /// a reading finishes, so the caller can ask again.
    func lines(in rect: CGRect, of window: NSWindow, ready: @escaping @MainActor () -> Void) -> [Line]? {
        let key = Key(window: window.windowNumber, rect: [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) })
        let cached = read[key]
        if let cached, Date().timeIntervalSince(cached.at) < Self.freshFor { return cached.lines }
        guard !reading.contains(key) else { return cached?.lines }
        guard let shot = WindowCapture.ownWindow(window),
              let pixels = Geometry.cropRect(
                  rect, margin: 0, scale: shot.scale,
                  imageSize: CGSize(width: shot.image.width, height: shot.image.height)),
              let image = shot.image.cropping(to: pixels)
        else {
            read[key] = (Date(), [])
            return []
        }
        reading.insert(key)
        let frame = CGRect(
            x: pixels.minX / shot.scale, y: pixels.minY / shot.scale,
            width: pixels.width / shot.scale, height: pixels.height / shot.scale)
        Task.detached(priority: .userInitiated) {
            let found = Self.recognize(image)
            await MainActor.run { [weak self] in
                guard let self else { return }
                read[key] = (Date(), found.map { Line(text: $0.text, rect: Self.windowRect(box: $0.box, in: frame)) })
                reading.remove(key)
                ready()
            }
        }
        return cached?.lines
    }

    nonisolated static func recognize(_ image: CGImage) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    /// Vision measures from the bottom left, as a fraction of the image; notes measure in window
    /// points from the top left.
    nonisolated static func windowRect(box: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + (1 - box.maxY) * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height)
    }

    /// Whether to look inside an element for its lines. Text elements are already as exact as the
    /// app can make them, an element with parts of its own is searched through those, and anything
    /// tall or wide is a background or a list rather than one control.
    static func reads(inside hit: ElementReader.Hit, window: NSWindow) -> Bool {
        let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXTextField", "AXTextArea", "AXLink"]
        if let role = hit.element.role, textRoles.contains(role) { return false }
        guard !hit.hasParts else { return false }
        let frame = hit.screenFrame
        return frame.height <= 160 && frame.width * frame.height < window.frame.width * window.frame.height * 0.3
    }

    static func line(at point: CGPoint, in lines: [Line]) -> Line? {
        lines.filter { $0.rect.insetBy(dx: -4, dy: -3).contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    static func element(_ line: Line, in container: Note.Element) -> Note.Element {
        let outer = Note.Element.Ancestor(
            role: container.role, label: container.label ?? container.title ?? container.value,
            identifier: container.identifier)
        return Note.Element(roleDescription: roleDescription, label: line.text, ancestors: [outer] + container.ancestors)
    }
}
