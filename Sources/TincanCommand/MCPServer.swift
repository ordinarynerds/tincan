import Foundation
import ImageIO
import TincanCore
import UniformTypeIdentifiers

/// `tincan mcp`: the notes as Model Context Protocol tools over stdio, for agents that speak MCP.
///
/// Hand-written rather than built on an SDK so the package keeps no dependencies. Messages are
/// single lines of JSON on stdin and stdout; anything human goes to stderr.
public struct MCPServer {
    public var store: NoteStore
    public var now: () -> Date

    public init(store: NoteStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let version = "0.1.0"

    public func serve(
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) },
        write: (String) -> Void = { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    ) {
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                write(Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error: send one JSON-RPC message per line.")))
                continue
            }
            if let reply = handle(message) { write(Self.encode(reply)) }
        }
    }

    /// The reply to one message, or nil for a notification.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id.map { Self.error(id: $0, code: -32600, message: "Invalid request: no method.") }
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "tincan", "title": "Tincan", "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool. Call tools/list for the four Tincan tools.")
            }
            return Self.result(id: id, call(name, arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "tincan_list_notes": return try list(arguments)
            case "tincan_get_note": return try get(arguments)
            case "tincan_resolve_note":
                let summary = (arguments["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let summary, !summary.isEmpty else {
                    return Self.failure("Give a one-line summary of what changed, so the person can check the fix.")
                }
                let note = try store.resolve(try Self.id(arguments), summary: summary, at: now())
                return Self.text("Resolved \(note.id). Its pin leaves the app on the next refresh.")
            case "tincan_reopen_note":
                return Self.text("Reopened \(try store.reopen(try Self.id(arguments)).id).")
            default:
                return Self.failure("Unknown tool \(name).")
            }
        } catch let error as NoteStore.StoreError {
            return Self.failure("\(error) Call tincan_list_notes to see the ids.")
        } catch let error as ArgumentError {
            return Self.failure(error.message)
        } catch {
            return Self.failure("\(error)")
        }
    }

    struct ArgumentError: Error {
        var message: String
    }

    static func id(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else {
            throw ArgumentError(message: "Pass the note's id, or a unique start or end of it, as `id`.")
        }
        return id
    }

    func list(_ arguments: [String: Any]) throws -> [String: Any] {
        let statusName = arguments["status"] as? String ?? "open"
        let status: Note.Status?
        switch statusName {
        case "open": status = .open
        case "resolved": status = .resolved
        case "all": status = nil
        default: throw ArgumentError(message: "`status` is open, resolved or all.")
        }
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        let offset = max((arguments["offset"] as? Int) ?? 0, 0)
        let notes = store.notes(status: status)
        let page = Array(notes.dropFirst(offset).prefix(limit))
        let formatter = NoteFormatter(store: store, now: now())
        let hasMore = offset + page.count < notes.count
        var text = notes.isEmpty
            ? "No \(status.map { "\($0.rawValue) " } ?? "")notes in \(store.directory.path)."
            : "\(notes.count) \(status.map { "\($0.rawValue) " } ?? "")note\(notes.count == 1 ? "" : "s"), showing \(offset + 1)–\(offset + page.count). Get one with tincan_get_note to see its screenshots.\n\n"
                + page.map(formatter.line).joined(separator: "\n\n")
        if hasMore { text += "\n\nMore notes: call again with offset \(offset + page.count)." }
        let structured: [String: Any] = [
            "total": notes.count, "count": page.count, "offset": offset, "has_more": hasMore,
            "next_offset": hasMore ? offset + page.count : NSNull(),
            "notes": page.map { note in
                [
                    "id": note.id, "status": note.status.rawValue, "text": note.text,
                    "target": note.target.summary, "window": note.window.title,
                    "created": ISO8601DateFormatter().string(from: note.created),
                    "sent_to": note.handoff?.agent ?? NSNull(),
                ] as [String: Any]
            },
        ]
        return ["content": [["type": "text", "text": text]], "structuredContent": structured]
    }

    func get(_ arguments: [String: Any]) throws -> [String: Any] {
        let note = try store.note(matching: try Self.id(arguments))
        let includeImages = arguments["include_images"] as? Bool ?? true
        var content: [[String: Any]] = [["type": "text", "text": NoteFormatter(store: store, now: now()).detail(note)]]
        if includeImages {
            for (caption, name, edge) in [
                ("Element, as the person saw it:", note.images.element, 1200),
                ("Whole window, target outlined:", note.images.window, 1600),
            ] {
                guard let url = store.imageURL(name), let png = Self.png(url, maxEdge: edge) else { continue }
                content.append(["type": "text", "text": caption])
                content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            }
        }
        return ["content": content]
    }

    /// A PNG no longer than `maxEdge` pixels on its longest side. Full-size Retina window shots are
    /// several megabytes, which is context an agent should spend on the code instead.
    static func png(_ url: URL, maxEdge: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func text(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode the reply."}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static let instructions = """
        Tincan holds notes a person left on a running macOS app by pointing at it. Each note names the \
        element (accessibility role, label, value, identifier), the view class, where it sits in the \
        window, the app's context such as the current screen, and screenshots. Work oldest first: \
        tincan_get_note shows the screenshots; search the code for the identifier, then the label text \
        (also in string catalogs), then the view class. Fix what the note means, rebuild, look at the \
        result, then tincan_resolve_note with one line on what changed. Ask the person when a note is unclear.
        """

    static var idProperty: [String: Any] { [
        "type": "string",
        "description": "The note's id, such as 20261028-091502-k3f9, or any unique start or end of it such as k3f9.",
    ] }

    static var tools: [[String: Any]] { [
        [
            "name": "tincan_list_notes",
            "title": "List Tincan notes",
            "description": "List feedback notes left on the running app, oldest first, with where each was left and what it says. Open notes by default.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["open", "resolved", "all"], "default": "open", "description": "Which notes to list."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20, "description": "How many notes to return."],
                    "offset": ["type": "integer", "minimum": 0, "default": 0, "description": "How many notes to skip, for the next page."],
                ],
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "tincan_get_note",
            "title": "Get a Tincan note",
            "description": "Everything about one note: the element's role, label, value and identifier, the view class, its rect in the window, the app's context, and screenshots of the element and the whole window.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": idProperty,
                    "include_images": ["type": "boolean", "default": true, "description": "Attach the screenshots as images."],
                ],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "tincan_resolve_note",
            "title": "Resolve a Tincan note",
            "description": "Mark a note as handled once the fix is built and checked. The summary is shown to the person who left the note.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": idProperty,
                    "summary": ["type": "string", "description": "One line on what changed, such as \"Widened the size column so 0.1 GB of 15 GB fits\"."],
                ],
                "required": ["id", "summary"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "tincan_reopen_note",
            "title": "Reopen a Tincan note",
            "description": "Mark a resolved note as open again, when the fix did not hold.",
            "inputSchema": ["type": "object", "properties": ["id": idProperty], "required": ["id"]],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
    ] }
}
