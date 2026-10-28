import Observation
import TincanCore

/// What the controls show: whether review mode is on, whether clicks are going to the app, whether a
/// note is being written, the notes on disk and who is listening. Tincan owns it; the floating bar,
/// the notes list and the menu bar switch only read it.
@MainActor
@Observable
final class ReviewState {
    var isActive = false
    var isUsingApp = false
    var isComposing = false
    var notes: [Note] = []
    var listeners: [Listener] = []

    var open: [Note] { notes.filter { $0.status == .open } }
    var openCount: Int { notes.reduce(0) { $0 + ($1.status == .open ? 1 : 0) } }

    /// Fixes an agent made that nobody has looked at yet, oldest fix first.
    var fixesToCheck: [Note] {
        notes.filter(\.awaitsCheck).sorted { ($0.resolution?.at ?? $0.created) < ($1.resolution?.at ?? $1.created) }
    }

    /// Resolved notes, latest resolution first.
    var resolved: [Note] {
        notes.filter { $0.status == .resolved }
            .sorted { ($0.resolution?.at ?? $0.created) > ($1.resolution?.at ?? $1.created) }
    }

    /// The listener working on or waiting for a note, if the note was sent to one that is live.
    func listener(for note: Note) -> Listener? {
        guard let agent = note.handoff?.agent else { return nil }
        return listeners.first { $0.name.caseInsensitiveCompare(agent) == .orderedSame }
    }
}
