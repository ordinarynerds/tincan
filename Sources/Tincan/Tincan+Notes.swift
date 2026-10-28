import AppKit
import TincanCore

/// Notes as the app sees them: read from disk into `state`, opened at their pins, and checked once
/// an agent has fixed them.
extension Tincan {
    static let showsResolvedKey = "TincanShowsResolved"

    /// Whether review mode also pins resolved notes, in grey with a check, so they can be reopened
    /// where they were left.
    public static var showsResolved: Bool {
        get { UserDefaults.standard.bool(forKey: showsResolvedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: showsResolvedKey)
            session?.refreshPins()
        }
    }

    /// Opens a note's sheet at its pin, starting review mode first if it is off, so it can be edited,
    /// resolved, reopened or deleted where it was left.
    public static func open(noteID: String) {
        NSApp.activate()
        start()
        session?.show(noteID: noteID)
    }

    /// Steps through every fix an agent made that nobody has looked at yet, each at its pin with its
    /// before and after pictures, so each can be confirmed or sent back.
    public static func checkFixes() {
        guard !state.fixesToCheck.isEmpty else { return }
        NSApp.activate()
        start()
        session?.checkFixes(state.fixesToCheck.map(\.id))
    }

    /// Whether a note was left where the app is now, by the configuration's place keys.
    static func isHere(_ note: Note) -> Bool {
        note.isLeft(in: configuration.context(), keys: configuration.placeKeys)
    }

    /// Takes the app to where a note was left, when the app said how. True when it is there now.
    static func go(to note: Note) -> Bool {
        if isHere(note) { return true }
        guard let navigate = configuration.navigate else { return false }
        return navigate(note.context)
    }

    /// Why a note cannot be opened at its pin right now, or nil when it can.
    static func whyNotOpenable(_ note: Note) -> String? {
        if state.isComposing { return BarView.composingReason }
        let open = (NSApp?.windows ?? []).contains { ReviewSession.isReviewable($0) && $0.title == note.window.title }
        return open ? nil : windowClosedReason(note)
    }

    static func windowClosedReason(_ note: Note) -> String {
        note.window.title.isEmpty
            ? "The window this note was left on is not open."
            : "“\(note.window.title)” is not open. Open it to see this note at its pin."
    }

    /// The values of the context entries that make up a place, such as `storage`.
    static func placeName(_ note: Note) -> String {
        let keys = configuration.placeKeys
        return note.context.filter { keys?.contains($0.key) ?? true }.sorted { $0.key < $1.key }
            .map(\.value).joined(separator: ", ")
    }

    /// Where a note was left, for a note that is somewhere else than the screen showing.
    static func elsewhere(_ note: Note) -> String {
        let place = placeName(note)
        return place.isEmpty ? "Left somewhere else in the app." : "Left on \(place). Go there to see it in place."
    }

    /// A note changed from a menu or the list: read everything again now rather than on the next tick.
    static func notesEdited() {
        refreshNotes()
    }

    /// Reads the notes and listeners again and redraws whatever shows them.
    static func refreshNotes() {
        guard let store else { return }
        let notes = store.all()
        let listeners = store.listeners(at: Date())
        if notes != state.notes { state.notes = notes }
        if listeners != state.listeners { state.listeners = listeners }
        stateChanged()
        session?.refreshPins()
    }
}
