import Foundation
import Testing

@testable import TincanCommand
@testable import TincanCore

@Suite("Sending a note to a listening agent")
struct ListenerTests {
    let store = NoteStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("tincan-listen-\(UUID().uuidString)"))
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func sent(_ id: String, to agent: String, delivered: Date? = nil) -> Note {
        var note = NoteStoreTests.note(id)
        note.handoff = Note.Handoff(agent: agent, sent: start, delivered: delivered)
        return note
    }

    @Test("a listener is offered only until its lease runs out")
    func lease() throws {
        try store.announce(Listener(name: "Claude", state: .waiting, until: start.addingTimeInterval(8)))
        #expect(store.listeners(at: start).map(\.name) == ["Claude"])
        #expect(store.listeners(at: start.addingTimeInterval(9)).isEmpty)
    }

    @Test("a listener's name decides its file, so Claude and claude are one listener")
    func names() throws {
        #expect(Listener.fileName(for: "Claude") == "claude.json")
        #expect(Listener.fileName(for: "Claude Code") == "claude-code.json")
        #expect(Listener.fileName(for: "../..") == "agent.json")
        try store.announce(Listener(name: "Claude", state: .waiting, until: start.addingTimeInterval(8)))
        try store.announce(Listener(name: "claude", state: .working, until: start.addingTimeInterval(8)))
        #expect(store.listeners(at: start).count == 1)
    }

    @Test("only open notes sent to this agent and not yet handed over are pending")
    func pending() throws {
        try store.save(sent("20260101-000000-aaaa", to: "Claude"))
        try store.save(sent("20260101-000001-bbbb", to: "claude"))
        try store.save(sent("20260101-000002-cccc", to: "Codex"))
        try store.save(sent("20260101-000003-dddd", to: "Claude", delivered: start))
        try store.save(NoteStoreTests.note("20260101-000004-eeee"))
        #expect(store.pendingHandoffs(for: "CLAUDE").map(\.id) == ["20260101-000000-aaaa", "20260101-000001-bbbb"])
        try store.markDelivered("aaaa", at: start)
        #expect(store.pendingHandoffs(for: "Claude").map(\.id) == ["20260101-000001-bbbb"])
    }

    @Test("watch --once hands over what is waiting, marks it delivered, and says the agent is working")
    func watchOnce() throws {
        try store.save(sent("20260101-000000-aaaa", to: "Claude"))
        try store.save(sent("20260101-000001-bbbb", to: "Codex"))
        var out: [String] = []
        let command = Command(
            arguments: ["watch", "--as", "Claude", "--once", "--json", "--dir", store.directory.path], environment: [:],
            now: { start }, out: { out.append($0) }, err: { _ in })
        #expect(command.run() == 0)
        #expect(out.count == 1)
        #expect(out[0].contains("20260101-000000-aaaa"))
        #expect(try store.note(matching: "aaaa").handoff?.delivered == start)
        #expect(try store.note(matching: "bbbb").handoff?.delivered == nil)
        let listener = try #require(store.listeners(at: start.addingTimeInterval(60)).first)
        #expect(listener.state == .working)
        #expect(listener.until == start.addingTimeInterval(Listener.workingLease))
    }

    @Test("a sent note says who has it and whether it was handed over")
    func formatting() throws {
        let formatter = NoteFormatter(store: store, now: start.addingTimeInterval(120))
        #expect(formatter.line(sent("20260101-000000-aaaa", to: "Claude")).contains("Sent to: Claude, waiting for Claude to listen"))
        #expect(formatter.line(sent("20260101-000000-aaaa", to: "Claude", delivered: start)).contains("Sent to: Claude, handed over 2 min ago"))
    }

    @Test("a note written before handoffs existed still reads")
    func olderNotes() throws {
        let json = String(decoding: try NoteStore.encoder.encode(NoteStoreTests.note("20260101-000000-aaaa")), as: UTF8.self)
        #expect(!json.contains("handoff"))
        let decoded = try NoteStore.decoder.decode(Note.self, from: Data(json.utf8))
        #expect(decoded.handoff == nil)
    }
}
