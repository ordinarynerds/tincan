import AppKit
import TincanCore

/// What is under a point in a window, read from the window's own accessibility tree.
///
/// AppKit views answer through `NSAccessibilityProtocol`. SwiftUI answers with private node objects
/// that implement the same methods without declaring the protocol, so every read goes through a
/// guarded key-value lookup that works for both and never sends a selector the object lacks.
@MainActor
enum ElementReader {
    struct Hit {
        var element: Note.Element
        var screenFrame: CGRect
    }

    static func hit(at screenPoint: CGPoint, in window: NSWindow) -> Hit? {
        guard let found = window.accessibilityHitTest(screenPoint) as? NSObject else { return nil }
        if found === window || found === window.contentView?.superview { return nil }
        guard let frame = frame(of: found), frame.width > 0, frame.height > 0 else { return nil }
        if Geometry.coversWindow(frame, windowFrame: window.frame) { return nil }
        return Hit(element: element(from: found, frame: frame), screenFrame: frame)
    }

    /// The class of the deepest view under the point. For SwiftUI this names the hosting view and
    /// with it the root view type, which is often the fastest way into the code.
    static func viewName(at screenPoint: CGPoint, in window: NSWindow) -> String? {
        guard let frameView = window.contentView?.superview else { return nil }
        let point = frameView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard let view = frameView.hitTest(point) else { return nil }
        var current: NSView? = view
        while let candidate = current {
            let name = String(describing: type(of: candidate))
            if !name.hasPrefix("_") && !name.hasPrefix("NSTheme") { return name }
            current = candidate.superview
        }
        return String(describing: type(of: view))
    }

    /// A control often answers through an inner part, such as a button's cell, that covers the same
    /// rect but carries none of the names set on the control. Those names are filled in from the
    /// nearest ancestor occupying the same space.
    static func element(from object: NSObject, frame: CGRect) -> Note.Element {
        var element = element(from: object)
        if let control = (object as? NSCell)?.controlView {
            element.identifier = element.identifier ?? string(control, "accessibilityIdentifier")
            element.label = element.label ?? string(control, "accessibilityLabel")
            element.help = element.help ?? string(control, "accessibilityHelp") ?? control.toolTip
        }
        var current = read(object, "accessibilityParent") as? NSObject
        var steps = 0
        while let node = current, steps < 4, !(node is NSWindow),
              let nodeFrame = Self.frame(of: node), nodeFrame.insetBy(dx: -1, dy: -1).contains(frame),
              frame.insetBy(dx: -1, dy: -1).contains(nodeFrame) {
            element.identifier = element.identifier ?? string(node, "accessibilityIdentifier")
            element.label = element.label ?? string(node, "accessibilityLabel")
            element.help = element.help ?? string(node, "accessibilityHelp")
            current = read(node, "accessibilityParent") as? NSObject
            steps += 1
        }
        return element
    }

    static func element(from object: NSObject) -> Note.Element {
        Note.Element(
            role: string(object, "accessibilityRole"),
            subrole: string(object, "accessibilitySubrole"),
            roleDescription: string(object, "accessibilityRoleDescription"),
            label: string(object, "accessibilityLabel"),
            title: string(object, "accessibilityTitle"),
            value: string(object, "accessibilityValue"),
            help: string(object, "accessibilityHelp"),
            identifier: string(object, "accessibilityIdentifier"),
            ancestors: ancestors(of: object))
    }

    static func ancestors(of object: NSObject, limit: Int = 6) -> [Note.Element.Ancestor] {
        var result: [Note.Element.Ancestor] = []
        var current = read(object, "accessibilityParent") as? NSObject
        var steps = 0
        while let node = current, steps < 24, result.count < limit, !(node is NSWindow) {
            let label = string(node, "accessibilityLabel") ?? string(node, "accessibilityTitle")
            let identifier = string(node, "accessibilityIdentifier")
            if label != nil || identifier != nil {
                result.append(.init(role: string(node, "accessibilityRole"), label: label, identifier: identifier))
            }
            current = read(node, "accessibilityParent") as? NSObject
            steps += 1
        }
        return result
    }

    static func frame(of object: NSObject) -> CGRect? {
        (read(object, "accessibilityFrame") as? NSValue)?.rectValue
    }

    static func read(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    static func string(_ object: NSObject, _ key: String, limit: Int = 300) -> String? {
        let text: String?
        switch read(object, key) {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        case let value as NSNumber: text = value.stringValue
        case let value as URL: text = value.absoluteString
        default: text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// SwiftUI builds its accessibility tree only once an accessibility client has spoken to the
    /// app. Asking the app one question about itself, from off the main thread so the main thread
    /// is free to answer, is enough. It needs no Accessibility permission.
    static func wake() async {
        let pid = ProcessInfo.processInfo.processIdentifier
        await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &value)
        }.value
    }
}
