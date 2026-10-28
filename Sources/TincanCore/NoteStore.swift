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

        public var description: String {
            switch self {
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
        note.status = .resolved
        note.resolution = Note.Resolution(at: date, summary: summary)
        try write(note)
        return note
    }

    @discardableResult
    public func reopen(_ query: String) throws -> Note {
        var note = try note(matching: query)
        note.status = .open
        note.resolution = nil
        try write(note)
        return note
    }

    public func delete(_ query: String) throws {
        let note = try note(matching: query)
        let fileManager = FileManager.default
        for name in [note.images.element, note.images.window].compactMap({ $0 }) {
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
