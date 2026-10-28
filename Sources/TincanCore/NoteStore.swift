import Foundation

/// Notes on disk: one JSON file per note in `notes/`, its pictures in `images/`.
///
/// One file per note means the app writing a new note and an agent resolving an old one never touch
/// the same file, so neither needs a lock.
public struct NoteStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var notesDirectory: URL { directory.appendingPathComponent("notes", isDirectory: true) }
    public var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, [String])
        case emptyText

        public var description: String {
            switch self {
            case .emptyText: "A note needs words. Delete it instead if nothing should change."
            case .notFound(let id): "No note matches “\(id)”."
            case .ambiguous(let id, let matches):
                "“\(id)” matches \(matches.count) notes: \(matches.joined(separator: ", "))."
            }
        }
    }

    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let ignore = directory.appendingPathComponent(".gitignore")
        if !fileManager.fileExists(atPath: ignore.path) {
            try Data("*\n".utf8).write(to: ignore, options: .atomic)
        }
    }

    /// Writes the pictures first and the note last, so a reader never finds a note whose images are missing.
    @discardableResult
    public func save(_ note: Note, elementImage: Data? = nil, windowImage: Data? = nil) throws -> Note {
        try prepare()
        var saved = note
        if let elementImage {
            let name = "\(note.id)-element.png"
            try elementImage.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            saved.images.element = name
        }
        if let windowImage {
            let name = "\(note.id)-window.png"
            try windowImage.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            saved.images.window = name
        }
        try write(saved)
        return saved
    }

    public func write(_ note: Note) throws {
        try prepare()
        try Self.encoder.encode(note).write(to: url(of: note.id), options: .atomic)
    }

    /// Every readable note, oldest first. A file that does not decode is skipped rather than fatal.
    public func all() -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: notesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    public func notes(status: Note.Status?) -> [Note] {
        all().filter { status == nil || $0.status == status }
    }

    /// Finds a note by its full id, or by any unambiguous prefix or suffix of it.
    public func note(matching query: String) throws -> Note {
        let notes = all()
        if let exact = notes.first(where: { $0.id == query }) { return exact }
        let matches = notes.filter { $0.id.hasPrefix(query) || $0.id.hasSuffix(query) }
        switch matches.count {
        case 0: throw StoreError.notFound(query)
        case 1: return matches[0]
        default: throw StoreError.ambiguous(query, matches.map(\.id))
        }
    }

    @discardableResult
    public func resolve(_ query: String, summary: String?, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        let summary = Self.trimmed(summary)
        note.status = .resolved
        note.resolution = Note.Resolution(at: date, summary: summary)
        note.history.append(Note.Event(kind: .resolved, at: date, text: summary))
        try write(note)
        return note
    }

    /// Opens the note again. Its resolution moves into the history rather than vanishing, so whoever
    /// picks it up next sees what was tried, and `reason` says why it did not hold.
    @discardableResult
    public func reopen(_ query: String, reason: String? = nil, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        if let resolution = note.resolution, note.history.last?.kind != .resolved {
            note.history.append(Note.Event(kind: .resolved, at: resolution.at, text: resolution.summary))
        }
        note.status = .open
        note.resolution = nil
        note.history.append(Note.Event(kind: .reopened, at: date, text: Self.trimmed(reason)))
        try write(note)
        return note
    }

    /// Rewrites what the note says, keeping the old wording in the history. Writing the same words
    /// again changes nothing.
    @discardableResult
    public func edit(_ query: String, text: String, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        guard let text = Self.trimmed(text) else { throw StoreError.emptyText }
        guard text != note.text else { return note }
        note.history.append(Note.Event(kind: .edited, at: date, text: note.text))
        note.text = text
        try write(note)
        return note
    }

    /// Queues the note for a listening agent, again if it already had it, so an edited or reopened
    /// note reaches the agent the way a new one does.
    @discardableResult
    public func send(_ query: String, to agent: String, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        note.handoff = Note.Handoff(agent: agent, sent: date)
        try write(note)
        return note
    }

    /// The person looked at the fix in the app and it is right. The note stays resolved and stops
    /// asking to be checked.
    @discardableResult
    public func confirm(_ query: String, at date: Date = Date()) throws -> Note {
        var note = try note(matching: query)
        guard note.status == .resolved else { return note }
        note.history.append(Note.Event(kind: .confirmed, at: date))
        try write(note)
        return note
    }

    /// Saves the picture the app took of the same spot after the fix, replacing an older one.
    @discardableResult
    public func attachAfter(_ query: String, image: Data, at date: Date = Date()) throws -> Note {
        try prepare()
        var note = try note(matching: query)
        let name = "\(note.id)-after.png"
        try image.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
        note.images.after = name
        note.images.afterAt = date
        try write(note)
        return note
    }

    /// Fixes an agent made that the person has not looked at yet, oldest fix first.
    public func fixesToCheck() -> [Note] {
        all().filter(\.awaitsCheck).sorted { ($0.resolution?.at ?? $0.created) < ($1.resolution?.at ?? $1.created) }
    }

    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public func delete(_ query: String) throws {
        let note = try note(matching: query)
        let fileManager = FileManager.default
        for name in [note.images.element, note.images.window, note.images.after].compactMap({ $0 }) {
            try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
        try fileManager.removeItem(at: url(of: note.id))
    }

    public func imageURL(_ name: String?) -> URL? {
        name.map { imagesDirectory.appendingPathComponent($0) }
    }

    func url(of id: String) -> URL {
        notesDirectory.appendingPathComponent("\(id).json")
    }

    /// Sortable by time, and short enough to type: `20261028-091502-k3f9`.
    public static func makeID(at date: Date = Date(), random: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let suffix = random ?? String((0..<4).map { _ in alphabet.randomElement() ?? "x" })
        return "\(stamp)-\(suffix)"
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
