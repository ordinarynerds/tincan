import Foundation

/// An agent waiting for notes. `tincan watch --as <name>` keeps one up to date in
/// `.tincan/listeners/`, and the note sheet offers to send a note only to a listener that is live, so
/// "Send to Claude" never claims a delivery nobody will pick up.
public struct Listener: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// `watch` is running and will print a sent note within its polling interval.
        case waiting
        /// `watch --once` handed over a note and exited; the agent is working on it and will listen
        /// again when it is done. A note sent now waits in the queue until then.
        case working
    }

    public var name: String
    public var state: State
    /// The listener counts as live until this moment. `watch` keeps pushing it forward.
    public var until: Date

    public init(name: String, state: State, until: Date) {
        self.name = name
        self.state = state
        self.until = until
    }

    /// How long an agent that took a note with `watch --once` still counts as coming back for more.
    public static let workingLease: TimeInterval = 30 * 60

    public func isLive(at date: Date) -> Bool { date < until }

    /// A file name from the listener's name, so `Claude` and `claude` are the same listener.
    public static func fileName(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "agent" : slug) + ".json"
    }
}

extension NoteStore {
    public var listenersDirectory: URL { directory.appendingPathComponent("listeners", isDirectory: true) }

    public func announce(_ listener: Listener) throws {
        try prepare()
        try FileManager.default.createDirectory(at: listenersDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(listener)
            .write(to: listenersDirectory.appendingPathComponent(Listener.fileName(for: listener.name)), options: .atomic)
    }

    /// Agents listening right now, by name.
    public func listeners(at date: Date = Date()) -> [Listener] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: listenersDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Listener.self, from: Data(contentsOf: $0)) }
            .filter { $0.isLive(at: date) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Open notes sent to this agent and not yet handed over, oldest first.
    public func pendingHandoffs(for agent: String) -> [Note] {
        notes(status: .open).filter {
            guard let handoff = $0.handoff, handoff.delivered == nil else { return false }
            return handoff.agent.caseInsensitiveCompare(agent) == .orderedSame
        }
    }

    @discardableResult
    public func markDelivered(_ query: String, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        note.handoff?.delivered = date
        try write(note)
        return note
    }
}
