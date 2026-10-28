import Foundation
import Testing

@testable import TincanCore

@Suite("Notes on disk")
struct NoteStoreTests {
    let root: URL
    let store: NoteStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-\(UUID().uuidString)")
        store = NoteStore(directory: root.appendingPathComponent(".tincan"))
    }

    static func note(_ id: String, text: String = "The label is cut off", at seconds: TimeInterval = 0) -> Note {
        Note(
            id: id, created: Date(timeIntervalSince1970: 1_800_000_000 + seconds), text: text,
            app: .init(bundleID: "com.example.app", name: "Example", version: "1.0", build: "7"),
            context: ["screen": "Settings"],
            window: .init(title: "Settings", identifier: nil, size: .init(width: 800, height: 600), scale: 2),
            target: .init(
                kind: .element, rect: .init(x: 10, y: 20, width: 80, height: 24),
                element: .init(role: "AXButton", label: "Save", identifier: "settings.save"),
                view: "NSHostingView<SettingsView>"))
    }

    @Test("a saved note reads back field for field, with its images beside it")
    func roundTrip() throws {
        let saved = try store.save(Self.note("20260101-000000-aaaa"), elementImage: Data([1, 2]), windowImage: Data([3]))
        #expect(saved.images.element == "20260101-000000-aaaa-element.png")
        #expect(saved.images.window == "20260101-000000-aaaa-window.png")
        #expect(store.all() == [saved])
        let element = try #require(store.imageURL(saved.images.element))
        #expect(try Data(contentsOf: element) == Data([1, 2]))
    }

    @Test("the notes folder ignores itself, so notes never land in a commit by accident")
    func ignoresItself() throws {
        try store.save(Self.note("20260101-000000-aaaa"))
        let ignore = try String(contentsOf: store.directory.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignore == "*\n")
    }

    @Test("notes list oldest first, and a status filter keeps only that status")
    func ordering() throws {
        try store.save(Self.note("20260101-000002-cccc", at: 2))
        try store.save(Self.note("20260101-000001-bbbb", at: 1))
        try store.resolve("cccc", summary: "Fixed")
        #expect(store.all().map(\.id) == ["20260101-000001-bbbb", "20260101-000002-cccc"])
        #expect(store.notes(status: .open).map(\.id) == ["20260101-000001-bbbb"])
        #expect(store.notes(status: .resolved).first?.resolution?.summary == "Fixed")
    }

    @Test("an id can be typed as any unique start or end of it, and an ambiguous one names the matches")
    func matching() throws {
        try store.save(Self.note("20260101-000001-bbbb"))
        try store.save(Self.note("20260101-000002-cccc"))
        #expect(try store.note(matching: "cccc").id == "20260101-000002-cccc")
        #expect(try store.note(matching: "20260101-000001").id == "20260101-000001-bbbb")
        #expect(throws: NoteStore.StoreError.notFound("zzzz")) { try store.note(matching: "zzzz") }
        #expect(throws: NoteStore.StoreError.ambiguous("20260101", ["20260101-000001-bbbb", "20260101-000002-cccc"])) {
            try store.note(matching: "20260101")
        }
    }

    @Test("reopening clears the resolution, and deleting removes the images too")
    func reopenAndDelete() throws {
        try store.save(Self.note("20260101-000001-bbbb"), elementImage: Data([1]))
        try store.resolve("bbbb", summary: "Done")
        let reopened = try store.reopen("bbbb")
        #expect(reopened.status == .open)
        #expect(reopened.resolution == nil)
        try store.delete("bbbb")
        #expect(store.all().isEmpty)
        let images = try FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path)
        #expect(images.isEmpty)
    }

    @Test("reopening keeps the fix that did not hold in the history, with the reason it came back")
    func reopenKeepsHistory() throws {
        try store.save(Self.note("20260101-000001-bbbb"))
        try store.resolve("bbbb", summary: "  Widened the column  ", at: Date(timeIntervalSince1970: 10))
        let reopened = try store.reopen("bbbb", reason: "Still clipped at the largest text size", at: Date(timeIntervalSince1970: 20))
        #expect(reopened.history.map(\.kind) == [.resolved, .reopened])
        #expect(reopened.lastReopening?.undid?.text == "Widened the column")
        #expect(reopened.lastReopening?.reopened.text == "Still clipped at the largest text size")
        #expect(try store.reopen("bbbb", reason: "   ").history.last?.text == nil)
    }

    @Test("a note resolved before notes had a history still keeps its fix when reopened")
    func reopenLegacyResolution() throws {
        var note = Self.note("20260101-000001-bbbb")
        note.status = .resolved
        note.resolution = .init(at: Date(timeIntervalSince1970: 5), summary: "Old fix")
        try store.write(note)
        let reopened = try store.reopen("bbbb")
        #expect(reopened.history.first == Note.Event(kind: .resolved, at: Date(timeIntervalSince1970: 5), text: "Old fix"))
    }

    @Test("editing keeps the old words in the history, the same words change nothing, and no words is refused")
    func edit() throws {
        try store.save(Self.note("20260101-000001-bbbb", text: "Too tight"))
        let edited = try store.edit("bbbb", text: " The size column cuts off 0.1 GB \n")
        #expect(edited.text == "The size column cuts off 0.1 GB")
        #expect(edited.history == [Note.Event(kind: .edited, at: try #require(edited.history.first?.at), text: "Too tight")])
        #expect(try store.edit("bbbb", text: "The size column cuts off 0.1 GB").history.count == 1)
        #expect(throws: NoteStore.StoreError.emptyText) { try store.edit("bbbb", text: "  ") }
    }

    @Test("sending a note again queues it for the agent even after it was handed over")
    func sendAgain() throws {
        try store.save(Self.note("20260101-000001-bbbb"))
        try store.send("bbbb", to: "Claude")
        try store.markDelivered("bbbb")
        #expect(store.pendingHandoffs(for: "claude").isEmpty)
        try store.send("bbbb", to: "Claude")
        #expect(store.pendingHandoffs(for: "Claude").map(\.id) == ["20260101-000001-bbbb"])
    }

    @Test("a schema 1 note, written before history existed, still reads, with an empty history")
    func readsSchemaOne() throws {
        var json = try JSONSerialization.jsonObject(with: NoteStore.encoder.encode(Self.note("20260101-000001-bbbb"))) as? [String: Any] ?? [:]
        json["schema"] = 1
        json.removeValue(forKey: "history")
        try store.prepare()
        try JSONSerialization.data(withJSONObject: json).write(to: store.notesDirectory.appendingPathComponent("20260101-000001-bbbb.json"))
        let note = try store.note(matching: "bbbb")
        #expect(note.schema == 1)
        #expect(note.history.isEmpty)
        #expect(try store.edit("bbbb", text: "New words").history.count == 1)
    }

    @Test("a file that is not a note is skipped instead of breaking the list")
    func skipsGarbage() throws {
        try store.save(Self.note("20260101-000001-bbbb"))
        try Data("not json".utf8).write(to: store.notesDirectory.appendingPathComponent("broken.json"))
        #expect(store.all().count == 1)
    }

    @Test("ids sort by time and read as UTC date, time and a short suffix")
    func ids() {
        let id = NoteStore.makeID(at: Date(timeIntervalSince1970: 0), random: "k3f9")
        #expect(id == "19700101-000000-k3f9")
        #expect(NoteStore.makeID().count == 20)
    }

    @Test("an element is named the way a person would say it")
    func summaries() {
        #expect(Note.Element(role: "AXButton", label: "Save").summary == "Button “Save”")
        #expect(Note.Element(role: "AXStaticText", value: "76 GB").summary == "Static text “76 GB”")
        #expect(Note.Element(role: "AXCheckBox", roleDescription: "toggle", label: "Wi-Fi").summary == "Toggle “Wi-Fi”")
        #expect(Note.Element(role: "AXGroup").summary == "Group")
    }
}
