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

    static let valueOptions: Set<String> = ["--dir", "-m", "--message", "--interval", "--as", "--timeout"]

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
                let note = try store.reopen(
                    try required(rest, "reopen <id> [-m \"what is still wrong\"]"),
                    reason: options.values["-m"] ?? options.values["--message"], at: now())
                out("Reopened \(note.id)")
            case "edit":
                let id = try required(rest, "edit <id> -m \"what the note should say\"")
                guard let text = options.values["-m"] ?? options.values["--message"] else {
                    throw UsageError(usage: "edit <id> -m \"what the note should say\"")
                }
                out("Edited \(try store.edit(id, text: text, at: now()).id)")
            case "delete", "rm":
                let id = try store.note(matching: try required(rest, "delete <id>")).id
                try store.delete(id)
                out("Deleted \(id)")
            case "path":
                out(store.directory.path)
            case "watch":
                watch(
                    store: store, json: json, interval: Double(options.values["--interval"] ?? "") ?? 1,
                    name: options.values["--as"] ?? environment["TINCAN_AGENT"] ?? "Agent",
                    once: options.flags.contains("--once"), all: options.flags.contains("--all"))
            case "check":
                return check(store: store, timeout: Double(options.values["--timeout"] ?? "") ?? 15)
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

    /// Listens as an agent: announces itself so the app offers "Send to <name> now", and prints each
    /// note sent to it the moment it arrives. With `--once` it stops after the first note it hands
    /// over, for agents that are told when a background command ends rather than when it prints.
    /// With `--all` it also prints every new note, sent or not.
    func watch(store: NoteStore, json: Bool, interval: Double, name: String, once: Bool, all: Bool) {
        var seen = Set(store.all().map(\.id))
        let interval = max(0.2, interval)
        let lease = interval * 3 + 5
        err("Listening as \(name) in \(store.directory.path). Notes sent to \(name) print as they arrive\(once ? ", then this stops" : ""). Stop with Control-C.")
        while true {
            try? store.announce(Listener(name: name, state: .waiting, until: now().addingTimeInterval(lease)))
            var handed = false
            for note in store.pendingHandoffs(for: name) {
                emit(note, store: store, json: json)
                _ = try? store.markDelivered(note.id, at: now())
                seen.insert(note.id)
                handed = true
            }
            if all {
                for note in store.notes(status: .open) where !seen.contains(note.id) {
                    emit(note, store: store, json: json)
                    seen.insert(note.id)
                    handed = true
                }
            }
            if once && handed {
                try? store.announce(Listener(name: name, state: .working, until: now().addingTimeInterval(Listener.workingLease)))
                return
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Asks the running app that writes to this store to check its own windows, then prints the report
    /// it writes. The app does the checking because only it can see what pointing at its windows returns.
    func check(store: NoteStore, timeout: Double) -> Int32 {
        let directory = store.directory.appendingPathComponent("checks", isDirectory: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.ordinarynerds.tincan.check"), object: store.directory.standardizedFileURL.path,
            userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if let fresh = names.filter({ !before.contains($0) && $0.hasSuffix(".md") }).sorted().last,
               let text = try? String(contentsOf: directory.appendingPathComponent(fresh), encoding: .utf8) {
                out(text)
                return 0
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        err("No app answered within \(Int(timeout)) s. The app has to be running with Tincan installed and writing to \(store.directory.path).")
        return 1
    }

    func emit(_ note: Note, store: NoteStore, json: Bool) {
        if json, let line = try? jsonLine(note) {
            out(line)
        } else {
            out(NoteFormatter(store: store, now: now()).line(note) + "\n")
        }
        fflush(stdout)
    }

    public static let usage = """
        tincan: read the notes people leave on a running macOS app.

        Usage:
          tincan list [--all | --resolved] [--json]   Open notes, oldest first
          tincan show <id> [--json]                   Everything about one note
          tincan resolve <id> [-m "what changed"]     Mark a note as handled
          tincan reopen <id> [-m "what is still wrong"]
                                                      Mark it open again, saying why
          tincan edit <id> -m "new words"             Rewrite a note; the old words stay in its history
          tincan delete <id>                          Remove a note and its images
          tincan watch --as <name> [--once] [--all] [--json]
                                                      Listen as an agent: print notes sent to <name>
          tincan check [--timeout <s>]                Have the running app check its windows: what
                                                      can't be pointed at, unnamed controls, elements
                                                      that swallow their contents
          tincan path                                 Where notes are stored
          tincan agents                               How an agent should work through notes
          tincan mcp                                  Serve the notes to an agent over MCP (stdio)

        An <id> can be the full id or any unique start or end of it.
        While `watch --as Claude` runs, the app offers "Send to Claude now" on each note. --once stops
        after handing over a note; --all also prints new notes nobody sent. TINCAN_AGENT sets the name.
        Notes are found in $TINCAN_DIR, else --dir, else .tincan at the root of the current git repository.
        """
}
