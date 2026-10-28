import Foundation
import Testing

@testable import TincanCommand
@testable import TincanCore

@Suite("Checking fixes and finding notes again")
struct FixCheckTests {
    let store = NoteStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("tincan-fix-\(UUID().uuidString)"))

    @Test("a fix an agent made waits to be checked until the person confirms it or reopens the note")
    func awaitsCheck() throws {
        try store.save(NoteStoreTests.note("20260101-000001-bbbb"))
        #expect(!(try store.note(matching: "bbbb")).awaitsCheck)
        try store.resolve("bbbb", summary: "Widened the column")
        #expect(try store.note(matching: "bbbb").awaitsCheck)
        #expect(store.fixesToCheck().map(\.id) == ["20260101-000001-bbbb"])
        try store.confirm("bbbb")
        #expect(!(try store.note(matching: "bbbb")).awaitsCheck)
        #expect(store.fixesToCheck().isEmpty)
        #expect(try store.note(matching: "bbbb").status == .resolved)
    }

    @Test("a note resolved before history existed never asks to be checked")
    func legacyResolvedIsNotAFix() throws {
        var note = NoteStoreTests.note("20260101-000001-bbbb")
        note.status = .resolved
        note.resolution = .init(at: Date(timeIntervalSince1970: 5), summary: "Old")
        try store.write(note)
        #expect(store.fixesToCheck().isEmpty)
    }

    @Test("confirming an open note changes nothing")
    func confirmOpen() throws {
        try store.save(NoteStoreTests.note("20260101-000001-bbbb"))
        #expect(try store.confirm("bbbb").history.isEmpty)
    }

    @Test("fixes to check list the oldest fix first")
    func fixOrder() throws {
        try store.save(NoteStoreTests.note("20260101-000001-aaaa"))
        try store.save(NoteStoreTests.note("20260101-000002-bbbb", at: 1))
        try store.resolve("bbbb", summary: "First", at: Date(timeIntervalSince1970: 10))
        try store.resolve("aaaa", summary: "Second", at: Date(timeIntervalSince1970: 20))
        #expect(store.fixesToCheck().map(\.id) == ["20260101-000002-bbbb", "20260101-000001-aaaa"])
    }

    @Test("an after picture replaces the last one in place, records when, and is deleted with the note")
    func afterPicture() throws {
        try store.save(NoteStoreTests.note("20260101-000001-bbbb"))
        try store.resolve("bbbb", summary: "One", at: Date(timeIntervalSince1970: 10))
        let first = try store.attachAfter("bbbb", image: Data([9]), at: Date(timeIntervalSince1970: 11))
        #expect(first.images.after == "20260101-000001-bbbb-after.png")
        #expect(first.images.afterAt == Date(timeIntervalSince1970: 11))
        let again = try store.attachAfter("bbbb", image: Data([7]), at: Date(timeIntervalSince1970: 14))
        #expect(again.images.after == first.images.after)
        #expect(again.images.afterAt == Date(timeIntervalSince1970: 14))
        #expect(try Data(contentsOf: store.imagesDirectory.appendingPathComponent(first.images.after!)) == Data([7]))
        try store.delete("bbbb")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.imagesDirectory.path).isEmpty)
    }

    @Test("a note shows where it was left: by every context entry, by the place keys only, or everywhere without context")
    func place() {
        var note = NoteStoreTests.note("20260101-000001-bbbb")
        note.context = ["screen": "Settings", "selection": "row 3"]
        #expect(note.isLeft(in: ["screen": "Settings", "selection": "row 3"]))
        #expect(!note.isLeft(in: ["screen": "Settings", "selection": "row 4"]))
        #expect(note.isLeft(in: ["screen": "Settings", "selection": "row 4"], keys: ["screen"]))
        #expect(!note.isLeft(in: ["screen": "Overview"], keys: ["screen"]))
        #expect(!note.isLeft(in: [:], keys: ["screen"]))
        note.context = [:]
        #expect(note.isLeft(in: ["screen": "Anything"], keys: ["screen"]))
    }

    @Test("an element is found again by its identifier, or by its role and name; a line of text by what holds it")
    func anchors() throws {
        let button = Note.Element(role: "AXButton", label: "Save", identifier: "settings.save")
        let byID = try #require(button.anchor)
        #expect(byID.matches(role: "AXButton", name: "Keep", identifier: "settings.save"))
        #expect(!byID.matches(role: "AXButton", name: "Save", identifier: nil))
        #expect(!byID.matches(role: "AXCheckBox", name: "Save", identifier: "settings.save"))
        let byName = try #require(Note.Element(role: "AXButton", label: "Save").anchor)
        #expect(byName.matches(role: "AXButton", name: "Save", identifier: nil))
        #expect(!byName.matches(role: "AXButton", name: "Cancel", identifier: nil))
        #expect(!byName.matches(role: "AXLink", name: "Save", identifier: nil))
        let line = Note.Element(roleDescription: "text", label: "0.6 GB", ancestors: [.init(role: "AXButton", label: "Temporary Files", identifier: nil)])
        #expect(line.anchor == .init(role: "AXButton", label: "Temporary Files", identifier: nil))
        #expect(Note.Element(role: "AXGroup").anchor == nil)
    }

    @Test("an agent reading a fixed note sees the after picture and whether the person has checked it")
    func agentSeesTheCheck() throws {
        try store.save(NoteStoreTests.note("20260101-000001-bbbb"))
        try store.resolve("bbbb", summary: "Widened the column")
        try store.attachAfter("bbbb", image: Data([9]))
        let formatter = NoteFormatter(store: store, now: Date())
        let line = formatter.line(try store.note(matching: "bbbb"))
        #expect(line.contains("After image: \(store.imagesDirectory.path)/20260101-000001-bbbb-after.png"))
        #expect(line.contains("Checked: not yet"))
        try store.confirm("bbbb")
        let detail = formatter.detail(try store.note(matching: "bbbb"))
        #expect(detail.contains("Checked: the person looked at the fix and it is right"))
        #expect(detail.contains("the person checked the fix and it is right"))
        let server = MCPServer(store: store)
        let reply = try #require(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "tincan_list_notes", "arguments": ["status": "all"]],
        ])?["result"] as? [String: Any])
        let notes = try #require((reply["structuredContent"] as? [String: Any])?["notes"] as? [[String: Any]])
        #expect(notes.first?["awaiting_check"] as? Bool == false)
    }
}
