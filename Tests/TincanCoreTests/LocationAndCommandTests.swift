import Foundation
import Testing

@testable import TincanCommand
@testable import TincanCore

@Suite("Finding the notes folder")
struct LocationTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-loc-\(UUID().uuidString)")

    func makeRepo() throws -> URL {
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("AppDelegate.swift")
        try Data().write(to: file)
        return file
    }

    @Test("a source file inside a repository puts notes at the repository root")
    func repositoryRoot() throws {
        let file = try makeRepo()
        let resolved = TincanLocation.resolve(start: file, environment: [:])
        #expect(resolved.standardizedFileURL.path == root.appendingPathComponent(".tincan").standardizedFileURL.path)
    }

    @Test("TINCAN_DIR wins over everything, then an explicit folder")
    func precedence() throws {
        let file = try makeRepo()
        let explicit = URL(fileURLWithPath: "/tmp/explicit")
        #expect(TincanLocation.resolve(explicit: explicit, start: file, environment: ["TINCAN_DIR": "/tmp/env"]).path == "/tmp/env")
        #expect(TincanLocation.resolve(explicit: explicit, start: file, environment: [:]).path == "/tmp/explicit")
    }

    @Test("outside any repository, notes fall back to Application Support under the app's name")
    func fallback() {
        let resolved = TincanLocation.resolve(start: URL(fileURLWithPath: "/"), environment: [:], fallbackName: "com.example")
        #expect(resolved.path.hasSuffix("Application Support/Tincan/com.example"))
    }
}

@Suite("The tincan command")
struct CommandTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-cmd-\(UUID().uuidString)")

    func run(_ arguments: String...) -> (code: Int32, out: String, err: String) {
        let box = Output()
        let command = Command(
            arguments: arguments + ["--dir", directory.path], environment: [:],
            now: { Date(timeIntervalSince1970: 1_800_000_120) },
            out: { box.out.append($0) }, err: { box.err.append($0) })
        let code = command.run()
        return (code, box.out.joined(separator: "\n"), box.err.joined(separator: "\n"))
    }

    final class Output {
        var out: [String] = []
        var err: [String] = []
    }

    func seed() throws {
        try NoteStore(directory: directory).save(NoteStoreTests.note("20260101-000001-bbbb"), elementImage: Data([1]))
    }

    @Test("list names where, what was said, and the image path an agent can open")
    func list() throws {
        try seed()
        let result = run("list")
        #expect(result.code == 0)
        #expect(result.out.contains("1 open note in"))
        #expect(result.out.contains("Where: Button “Save” in “Settings” (screen: Settings)"))
        #expect(result.out.contains("Note: The label is cut off"))
        #expect(result.out.contains("Element image: \(directory.path)/images/20260101-000001-bbbb-element.png"))
        #expect(result.out.contains("2 min ago"))
    }

    @Test("show adds the fields that lead to the code: identifier, view, rect and context")
    func show() throws {
        try seed()
        let result = run("show", "bbbb")
        #expect(result.out.contains("Identifier: settings.save"))
        #expect(result.out.contains("View: NSHostingView<SettingsView>"))
        #expect(result.out.contains("Rect: x 10, y 20, 80 × 24 points"))
        #expect(result.out.contains("App: Example 1.0 (7), com.example.app"))
    }

    @Test("resolve takes a summary, and the note leaves the open list")
    func resolve() throws {
        try seed()
        #expect(run("resolve", "bbbb", "-m", "Widened the column").out == "Resolved 20260101-000001-bbbb")
        #expect(run("list").out.hasPrefix("No open notes"))
        #expect(run("list", "--resolved").out.contains("Resolved: just now, Widened the column"))
    }

    @Test("--json prints one parseable note per line")
    func json() throws {
        try seed()
        let line = run("list", "--json").out
        let note = try NoteStore.decoder.decode(Note.self, from: Data(line.utf8))
        #expect(note.id == "20260101-000001-bbbb")
    }

    @Test("a missing id and an unknown verb fail with usage, not a crash")
    func failures() {
        #expect(run("show").code == 64)
        #expect(run("frobnicate").code == 64)
        #expect(run("show", "nope").code == 1)
    }
}
