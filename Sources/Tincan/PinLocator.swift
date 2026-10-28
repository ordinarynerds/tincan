import AppKit
import TincanCore

/// Finds where a note's element is now. A note records a rect, but the window scrolls, resizes and
/// reflows, so a pin drawn at the old rect would point at whatever moved in. The element is looked
/// up again by its identifier, or its role and name: first at the old spot, which is cheap, then
/// anywhere in the window.
@MainActor
final class PinLocator {
    enum Placement: Equatable {
        /// The element is still at the spot the note recorded, or the note is a region.
        case here
        /// The element is somewhere else in the window now.
        case moved
        /// Nothing in the window is that element any more.
        case missing
    }

    struct Location: Equatable {
        var rect: CGRect
        var placement: Placement
    }

    private struct Search {
        var location: Location
        var at: Date
        var windowFrame: CGRect
    }

    /// Window-wide searches are kept briefly, since walking a large tree on every refresh is slow.
    private var searches: [String: Search] = [:]
    static let searchLifetime: TimeInterval = 3
    static let searchLimit = 6_000

    func locate(_ note: Note, in window: NSWindow, now: Date = Date()) -> Location {
        let stored = Geometry.cgRect(note.target.rect)
        guard let element = note.target.element, let anchor = element.anchor else {
            return Location(rect: stored, placement: .here)
        }
        let isLine = element.role == nil
        let centre = CGPoint(x: window.frame.minX + stored.midX, y: window.frame.maxY - stored.midY)
        if window.frame.contains(centre) {
            for hit in ElementReader.chain(at: centre, in: window).prefix(8) where Self.matches(anchor, hit.element) {
                let rect = Geometry.windowTopLeft(hit.screenFrame, in: window.frame)
                return Location(rect: isLine ? stored : rect, placement: .here)
            }
        }
        if let search = searches[note.id], search.windowFrame == window.frame,
           now.timeIntervalSince(search.at) < Self.searchLifetime {
            return search.location
        }
        let location = search(anchor, near: stored, in: window)
        searches[note.id] = Search(location: location, at: now, windowFrame: window.frame)
        return location
    }

    func forget() {
        searches = [:]
    }

    static func matches(_ anchor: Note.Element.Ancestor, _ element: Note.Element) -> Bool {
        let name = [element.label, element.title, element.value].compactMap { $0 }.first { !$0.isEmpty }
        return anchor.matches(role: element.role, name: name, identifier: element.identifier)
    }

    /// Every element in the window that is the anchor, nearest to where the note was left.
    private func search(_ anchor: Note.Element.Ancestor, near stored: CGRect, in window: NSWindow) -> Location {
        var best: (rect: CGRect, distance: CGFloat)?
        var visited = 0
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 40, visited < Self.searchLimit, seen.insert(ObjectIdentifier(node)).inserted else { return }
            visited += 1
            if !(node is NSWindow), let frame = ElementReader.frame(of: node), frame.width > 0, frame.height > 0,
               candidate(node, anchor) {
                let rect = Geometry.windowTopLeft(frame, in: window.frame)
                let distance = hypot(rect.midX - stored.midX, rect.midY - stored.midY)
                if best == nil || distance < best!.distance { best = (rect, distance) }
            }
            for child in (ElementReader.read(node, "accessibilityChildren") as? [NSObject]) ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        guard let best, CGRect(origin: .zero, size: window.frame.size).intersects(best.rect) else {
            return Location(rect: stored, placement: .missing)
        }
        return Location(rect: best.rect, placement: best.distance < 2 ? .here : .moved)
    }

    private func candidate(_ node: NSObject, _ anchor: Note.Element.Ancestor) -> Bool {
        let identity = ElementReader.identity(of: node)
        return anchor.matches(role: identity.role, name: identity.name, identifier: identity.identifier)
    }
}

/// The picture of a fixed spot as it looks now, taken when the person opens the fix to check it.
/// Taken then and not when the agent resolves the note, since the build running at that moment may
/// predate the fix; the build on screen while the person checks is the one they are judging.
@MainActor
enum AfterPictures {
    static func take(of note: Note, in window: NSWindow, at rect: CGRect, store: NoteStore) async -> NSImage? {
        guard let shot = await WindowCapture.capture(window),
              let crop = WindowCapture.crop(shot, to: rect),
              let png = WindowCapture.png(crop)
        else { return nil }
        _ = try? store.attachAfter(note.id, image: png)
        return NSImage(cgImage: crop, size: CGSize(width: CGFloat(crop.width) / shot.scale, height: CGFloat(crop.height) / shot.scale))
    }
}
