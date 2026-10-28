import Foundation
import TincanCore

/// The `tincan` command, kept out of `main.swift` so every path through it can be tested.
public struct Command {
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL
    public var now: () -> Date
    public var out: (String) -> Void
    public var err: (String) -> Void

    public init(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        now: @escaping () -> Date = Date.init,
        out: @escaping (String) -> Void = { print($0) },
        err: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.now = now
        self.out = out
        self.err = err
    }

    struct Options {
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
    }

    static let valueOptions: Set<String> = ["--dir", "-m", "--message", "--interval"]

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument), index + 1 < arguments.count {
                options.values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                options.flags.insert(argument)
            } else {
                options.positional.append(argument)
            }
            index += 1
        }
        return options
    }

    @discardableResult
    public func run() -> Int32 {
        let options = Self.parse(arguments)
        let verb = options.positional.first ?? "help"
        let rest = Array(options.positional.dropFirst())
        let store = NoteStore(directory: directory(options))
        let formatter = NoteFormatter(store: store, now: now())
        let json = options.flags.contains("--json")
        do {
            switch verb {
            case "list", "ls":
                let status: Note.Status? =
                    options.flags.contains("--all") ? nil
                    : options.flags.contains("--resolved") ? .resolved : .open
                let notes = store.notes(status: status)
                if json {
                    try notes.forEach { try out(jsonLine($0)) }
                } else if notes.isEmpty {
                    out("No \(status.map { "\($0.rawValue) " } ?? "")notes in \(store.directory.path)")
                } else {
                    out("\(notes.count) \(status.map { "\($0.rawValue) " } ?? "")note\(notes.count == 1 ? "" : "s") in \(store.directory.path)\n")
                    out(notes.map(formatter.line).joined(separator: "\n\n"))
                }
            case "show":
                let note = try store.note(matching: try required(rest, "show <id>"))
                out(json ? String(decoding: try NoteStore.encoder.encode(note), as: UTF8.self) : formatter.detail(note))
            case "resolve", "done":
                let note = try store.resolve(
                    try required(rest, "resolve <id> [-m summary]"),
                    summary: options.values["-m"] ?? options.values["--message"], at: now())
                out("Resolved \(note.id)")
            case "reopen":
                out("Reopened \(try store.reopen(try required(rest, "reopen <id>")).id)")
            case "delete", "rm":
                let id = try store.note(matching: try required(rest, "delete <id>")).id
                try store.delete(id)
                out("Deleted \(id)")
            case "path":
                out(store.directory.path)
            case "watch":
                watch(store: store, formatter: formatter, json: json, interval: Double(options.values["--interval"] ?? "") ?? 1)
            case "mcp":
                MCPServer(store: store, now: now).serve()
            case "agents", "guide":
                out(AgentGuide.text)
            case "help", "-h", "--help":
                out(Self.usage)
            default:
                err("Unknown command “\(verb)”.\n\n\(Self.usage)")
                return 64
            }
            return 0
        } catch let error as UsageError {
            err("Usage: tincan \(error.usage)")
            return 64
        } catch {
            err("\(error)")
            return 1
        }
    }

    struct UsageError: Error {
        var usage: String
    }

    func required(_ rest: [String], _ usage: String) throws -> String {
        guard let first = rest.first else { throw UsageError(usage: usage) }
        return first
    }

    func directory(_ options: Options) -> URL {
        let explicit = options.values["--dir"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        return TincanLocation.resolve(explicit: explicit, start: currentDirectory, environment: environment)
    }

    func jsonLine(_ note: Note) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(note), as: UTF8.self)
    }

    /// Prints each note that appears after it starts, until it is stopped. Built for agents that can
    /// watch a long-running command and act on every line it prints.
    func watch(store: NoteStore, formatter: NoteFormatter, json: Bool, interval: Double) {
        var seen = Set(store.all().map(\.id))
        err("Watching \(store.directory.path) for new notes. Stop with Control-C.")
        while true {
            Thread.sleep(forTimeInterval: max(0.2, interval))
            for note in store.notes(status: .open) where !seen.contains(note.id) {
                seen.insert(note.id)
                if json, let line = try? jsonLine(note) {
                    out(line)
                } else {
                    out(NoteFormatter(store: store, now: now()).line(note) + "\n")
                }
                fflush(stdout)
            }
        }
    }

    public static let usage = """
        tincan: read the notes people leave on a running macOS app.

        Usage:
          tincan list [--all | --resolved] [--json]   Open notes, oldest first
          tincan show <id> [--json]                   Everything about one note
          tincan resolve <id> [-m "what changed"]     Mark a note as handled
          tincan reopen <id>                          Mark it open again
          tincan delete <id>                          Remove a note and its images
          tincan watch [--json]                       Print new notes as they arrive
          tincan path                                 Where notes are stored
          tincan agents                               How an agent should work through notes
          tincan mcp                                  Serve the notes to an agent over MCP (stdio)

        An <id> can be the full id or any unique start or end of it.
        Notes are found in $TINCAN_DIR, else --dir, else .tincan at the root of the current git repository.
        """
}
