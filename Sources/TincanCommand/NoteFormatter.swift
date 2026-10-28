import Foundation
import TincanCore

/// How a note reads in a terminal. Written for an agent as much as for a person: labelled lines,
/// absolute image paths it can open directly, and nothing decorative to parse around.
public struct NoteFormatter: Sendable {
    public var store: NoteStore
    public var now: Date

    public init(store: NoteStore, now: Date = Date()) {
        self.store = store
        self.now = now
    }

    public func line(_ note: Note) -> String {
        var lines = ["\(note.id)  \(note.status.rawValue)  \(age(of: note.created))"]
        lines.append("  Where: \(place(note))")
        lines.append("  Note: \(note.text.replacingOccurrences(of: "\n", with: "\n        "))")
        if let path = store.imageURL(note.images.element)?.path { lines.append("  Element image: \(path)") }
        if let path = store.imageURL(note.images.window)?.path { lines.append("  Window image: \(path)") }
        if let handoff = note.handoff {
            lines.append("  Sent to: \(handoff.agent), \(handoff.delivered.map { "handed over \(age(of: $0))" } ?? "waiting for \(handoff.agent) to listen")")
        }
        if let resolution = note.resolution {
            lines.append("  Resolved: \(age(of: resolution.at))\(resolution.summary.map { ", \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    public func detail(_ note: Note) -> String {
        var lines = [line(note)]
        let rect = note.target.rect
        lines.append("  Rect: x \(format(rect.x)), y \(format(rect.y)), \(format(rect.width)) × \(format(rect.height)) points from the window's top left")
        if let element = note.target.element {
            let fields: [(String, String?)] = [
                ("Role", element.role), ("Subrole", element.subrole), ("Label", element.label),
                ("Title", element.title), ("Value", element.value), ("Help", element.help),
                ("Identifier", element.identifier),
            ]
            for (name, value) in fields {
                if let value, !value.isEmpty { lines.append("  \(name): \(value)") }
            }
            if !element.ancestors.isEmpty {
                let chain = element.ancestors.map { ancestor in
                    [ancestor.role.map(Note.Element.plainRole), ancestor.label.map { "“\($0)”" },
                     ancestor.identifier.map { "#\($0)" }]
                        .compactMap { $0 }.joined(separator: " ")
                }
                lines.append("  Inside: \(chain.joined(separator: " > "))")
            }
        }
        if let view = note.target.view { lines.append("  View: \(view)") }
        if !note.context.isEmpty {
            let pairs = note.context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            lines.append("  Context: \(pairs.joined(separator: ", "))")
        }
        let version = [note.app.version, note.app.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        lines.append("  App: \(note.app.name)\(version.isEmpty ? "" : " \(version)")\(note.app.bundleID.map { ", \($0)" } ?? "")")
        lines.append("  Window: “\(note.window.title)”, \(format(note.window.size.width)) × \(format(note.window.size.height)) points at \(format(note.window.scale))x")
        return lines.joined(separator: "\n")
    }

    func place(_ note: Note) -> String {
        var place = note.target.summary
        if !note.window.title.isEmpty { place += " in “\(note.window.title)”" }
        if !note.context.isEmpty {
            let pairs = note.context.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            place += " (\(pairs.joined(separator: ", ")))"
        }
        return place
    }

    func age(of date: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
