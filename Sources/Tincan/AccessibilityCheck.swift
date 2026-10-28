import AppKit
import os
import TincanCore

/// Walks a window's accessibility tree and asks, for every element, what pointing at its centre
/// returns. A person can only leave a note on what that answer reaches, and VoiceOver's pointer and
/// every other hit-testing tool are bound by the same answer, so an element present in the tree but
/// never returned is a defect in the app, not in the reader.
@MainActor
enum AccessibilityCheck {
    static let notification = Notification.Name("com.ordinarynerds.tincan.check")
    static let logger = Logger(subsystem: "com.ordinarynerds.tincan", category: "check")

    struct Finding {
        enum Kind: String {
            case unreachable = "Can't be pointed at"
            case unlabelled = "Control without a name"
            case swallowsChildren = "One element covering a large area"
        }

        var kind: Kind
        var element: String
        var frame: CGRect
        var detail: String
    }

    static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXRow", "AXCell", "AXSplitGroup", "AXOutline", "AXColumn",
        "AXToolbar", "AXWindow", "AXSplitter", "AXUnknown", "AXLayoutArea", "AXList", "AXTable",
    ]
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXTextField", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor", "AXLink",
    ]

    static func elements(in window: NSWindow) -> [NSObject] {
        var found: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if !(node is NSWindow) { found.append(node) }
            for child in (ElementReader.read(node, "accessibilityChildren") as? [NSObject]) ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return found
    }

    static func findings(in window: NSWindow, ignoring overlays: [NSWindow]) -> (checked: Int, findings: [Finding]) {
        var findings: [Finding] = []
        var checked = 0
        let windowArea = window.frame.width * window.frame.height
        for node in elements(in: window) {
            guard let frame = ElementReader.frame(of: node), frame.width > 2, frame.height > 2 else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard window.frame.contains(centre) else { continue }
            guard let role = ElementReader.string(node, "accessibilityRole"), !isScrollerPart(node) else { continue }
            let element = ElementReader.element(from: node, frame: frame)
            let name = element.label ?? element.title ?? element.value ?? ElementReader.string(node, "accessibilitySubrole")
            if controlRoles.contains(role), name == nil {
                let inside = texts(under: node)
                let contents = inside.isEmpty ? "" : " It contains “\(inside.joined(separator: "”, “"))”, which could be its name."
                findings.append(Finding(kind: .unlabelled, element: element.summary, frame: frame, detail: "\(role) with no label, title or value.\(contents)"))
            }
            let children = (ElementReader.read(node, "accessibilityChildren") as? [NSObject]) ?? []
            if !containerRoles.contains(role), name != nil, children.isEmpty, frame.width * frame.height > windowArea * 0.25 {
                findings.append(Finding(
                    kind: .swallowsChildren, element: element.summary, frame: frame,
                    detail: "Covers \(Int(frame.width * frame.height * 100 / windowArea))% of the window, so nothing inside it can be pointed at on its own."))
            }
            guard !containerRoles.contains(role) else { continue }
            checked += 1
            let raw = ElementReader.deepest(at: centre, in: window)
            if let raw, reaches(raw, node) || belongs(node, to: raw) || isPart(raw, of: node, role: role) { continue }
            findings.append(Finding(kind: .unreachable, element: element.summary, frame: frame, detail: describe(raw, window: window, overlays: overlays)))
        }
        return (checked, findings)
    }

    static func reaches(_ hit: NSObject, _ target: NSObject) -> Bool {
        var current: NSObject? = hit
        var steps = 0
        while let node = current, steps < 12 {
            if node === target { return true }
            current = ElementReader.read(node, "accessibilityParent") as? NSObject
            steps += 1
        }
        return false
    }

    static func texts(under node: NSObject, limit: Int = 4) -> [String] {
        var found: [String] = []
        func walk(_ element: NSObject, depth: Int) {
            guard depth < 8, found.count < limit else { return }
            for child in (ElementReader.read(element, "accessibilityChildren") as? [NSObject]) ?? [] {
                if let text = ElementReader.string(child, "accessibilityLabel") ?? ElementReader.string(child, "accessibilityValue") ?? ElementReader.string(child, "accessibilityTitle") {
                    found.append(String(text.prefix(50)))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(node, depth: 0)
        return found
    }

    /// Text inside a control, such as a field's placeholder, is reached by reaching the control.
    static func belongs(_ node: NSObject, to hit: NSObject) -> Bool {
        guard let role = ElementReader.string(hit, "accessibilityRole"), controlRoles.contains(role) else { return false }
        if reaches(node, hit) { return true }
        guard let outer = ElementReader.frame(of: hit), let inner = ElementReader.frame(of: node) else { return false }
        return outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    /// A control drawn by the system out of smaller pieces, such as a window's zoom button, answers
    /// with a piece of itself.
    static func isPart(_ hit: NSObject, of node: NSObject, role: String) -> Bool {
        guard controlRoles.contains(role), let outer = ElementReader.frame(of: node), let inner = ElementReader.frame(of: hit) else { return false }
        return outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    /// A scroll bar and its parts sit over the content they scroll and appear only while scrolling.
    static func isScrollerPart(_ node: NSObject) -> Bool {
        var current: NSObject? = node
        var steps = 0
        while let element = current, steps < 3 {
            if ElementReader.string(element, "accessibilityRole") == "AXScrollBar" { return true }
            current = ElementReader.read(element, "accessibilityParent") as? NSObject
            steps += 1
        }
        return false
    }

    static func title(of window: NSWindow) -> String {
        [window.title, window.accessibilityTitle() ?? "", ProcessInfo.processInfo.processName].first { !$0.isEmpty } ?? "Window"
    }

    static func describe(_ hit: NSObject?, window: NSWindow, overlays: [NSWindow]) -> String {
        guard let hit else { return "Pointing at its centre returns nothing." }
        if hit === window { return "Pointing at its centre returns the window itself." }
        if overlays.contains(where: { $0 === hit || $0.contentView === hit }) {
            return "Pointing at its centre returns Tincan's own overlay."
        }
        let role = ElementReader.string(hit, "accessibilityRole") ?? "?"
        let label = ElementReader.string(hit, "accessibilityLabel").map { " “\($0.prefix(40))”" } ?? ""
        let frame = ElementReader.frame(of: hit).map { " \(Int($0.width))×\(Int($0.height)) pt" } ?? ""
        return "Pointing at its centre returns \(role)\(label)\(frame), a \(String(describing: type(of: hit)).prefix(60))."
    }

    static func report(for windows: [NSWindow], overlays: [NSWindow], at date: Date) -> String {
        var lines = ["# Accessibility check", "", "\(date.formatted(.iso8601))", ""]
        for window in windows {
            let result = findings(in: window, ignoring: overlays)
            let unreachable = result.findings.filter { $0.kind == .unreachable }.count
            lines.append("## “\(title(of: window))”")
            lines.append("")
            lines.append("\(result.checked - unreachable) of \(result.checked) elements can be pointed at.")
            lines.append("")
            for kind in [Finding.Kind.unreachable, .swallowsChildren, .unlabelled] {
                let group = result.findings.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                lines.append("### \(kind.rawValue) (\(group.count))")
                lines.append("")
                for finding in group {
                    let top = Geometry.windowTopLeft(finding.frame, in: window.frame)
                    lines.append("- \(finding.element) at \(Int(top.minX)),\(Int(top.minY)) \(Int(top.width))×\(Int(top.height)). \(finding.detail)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func run(store: NoteStore) async {
        await ElementReader.wake()
        let windows = NSApp.windows.filter(ReviewSession.isReviewable)
        let overlays = windows.flatMap { $0.childWindows ?? [] }
        let date = Date()
        let text = report(for: windows, overlays: overlays, at: date)
        let directory = store.directory.appendingPathComponent("checks", isDirectory: true)
        do {
            try store.prepare()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
            try Data(text.utf8).write(to: directory.appendingPathComponent("check-\(stamp).md"), options: .atomic)
        } catch {
            logger.error("Writing the check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
