import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import TincanCommand
@testable import TincanCore

@Suite("The MCP server")
struct MCPServerTests {
    let store = NoteStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("tincan-mcp-\(UUID().uuidString)"))

    var server: MCPServer { MCPServer(store: store, now: { Date(timeIntervalSince1970: 1_800_000_120) }) }

    func request(_ method: String, id: Int = 1, _ params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try #require(server.handle(request("tools/call", ["name": tool, "arguments": arguments])))
        return try #require(reply["result"] as? [String: Any])
    }

    func texts(_ result: [String: Any]) -> [String] {
        (result["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("initialize answers with the client's protocol version when it is one we speak, else our newest")
    func initialize() throws {
        let known = try #require(server.handle(request("initialize", ["protocolVersion": "2025-03-26"]))?["result"] as? [String: Any])
        #expect(known["protocolVersion"] as? String == "2025-03-26")
        #expect((known["serverInfo"] as? [String: Any])?["name"] as? String == "tincan")
        #expect((known["capabilities"] as? [String: Any])?["tools"] != nil)
        let unknown = try #require(server.handle(request("initialize", ["protocolVersion": "1999-01-01"]))?["result"] as? [String: Any])
        #expect(unknown["protocolVersion"] as? String == MCPServer.supportedVersions[0])
    }

    @Test("a notification gets no reply, and an unknown method or tool is a protocol error")
    func protocolErrors() throws {
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let method = try #require(server.handle(request("resources/list"))?["error"] as? [String: Any])
        #expect(method["code"] as? Int == -32601)
        let tool = try #require(server.handle(request("tools/call", ["name": "tincan_explode"]))?["error"] as? [String: Any])
        #expect(tool["code"] as? Int == -32602)
    }

    @Test("tools/list offers the four tools, each with a schema and honest read-only hints")
    func toolList() throws {
        let result = try #require(server.handle(request("tools/list"))?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String }
            == ["tincan_list_notes", "tincan_get_note", "tincan_resolve_note", "tincan_reopen_note"])
        for tool in tools {
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
            let readOnly = (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
            #expect(readOnly == ["tincan_list_notes", "tincan_get_note"].contains(tool["name"] as? String))
        }
    }

    @Test("listing pages through open notes and says where the next page starts")
    func listing() throws {
        for index in 0..<3 {
            try store.save(NoteStoreTests.note("20260101-00000\(index)-aaa\(index)", text: "Note \(index)", at: Double(index)))
        }
        let first = try call("tincan_list_notes", ["limit": 2])
        let structured = try #require(first["structuredContent"] as? [String: Any])
        #expect(structured["total"] as? Int == 3)
        #expect(structured["has_more"] as? Bool == true)
        #expect(structured["next_offset"] as? Int == 2)
        #expect(texts(first)[0].contains("Note 0"))
        #expect(!texts(first)[0].contains("Note 2"))
        let second = try call("tincan_list_notes", ["limit": 2, "offset": 2])
        #expect((second["structuredContent"] as? [String: Any])?["has_more"] as? Bool == false)
        #expect(texts(second)[0].contains("Note 2"))
        let wrong = try call("tincan_list_notes", ["status": "closed"])
        #expect(wrong["isError"] as? Bool == true)
    }

    @Test("getting a note returns its words and both screenshots, scaled down to save the agent's context")
    func getNote() throws {
        try store.save(
            NoteStoreTests.note("20260101-000000-k3f9"),
            elementImage: try Self.png(width: 300, height: 100), windowImage: try Self.png(width: 3200, height: 2000))
        let result = try call("tincan_get_note", ["id": "k3f9"])
        let content = try #require(result["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "image" }
        #expect(images.count == 2)
        #expect(images.allSatisfy { $0["mimeType"] as? String == "image/png" })
        #expect(texts(result)[0].contains("The label is cut off"))
        let encoded = try #require(images[1]["data"] as? String)
        let window = try #require(Data(base64Encoded: encoded))
        let source = try #require(CGImageSourceCreateWithData(window as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
        let bare = try call("tincan_get_note", ["id": "k3f9", "include_images": false])
        #expect((bare["content"] as? [[String: Any]])?.count == 1)
    }

    @Test("resolving needs a summary, and a missing note is a tool error that points at the list")
    func resolving() throws {
        try store.save(NoteStoreTests.note("20260101-000000-k3f9"))
        #expect(try call("tincan_resolve_note", ["id": "k3f9"])["isError"] as? Bool == true)
        let missing = try call("tincan_resolve_note", ["id": "zzzz", "summary": "Fixed"])
        #expect(missing["isError"] as? Bool == true)
        #expect(texts(missing)[0].contains("tincan_list_notes"))
        let resolved = try call("tincan_resolve_note", ["id": "k3f9", "summary": "Widened the column"])
        #expect(resolved["isError"] == nil)
        let note = try store.note(matching: "k3f9")
        #expect(note.status == .resolved)
        #expect(note.resolution?.summary == "Widened the column")
        _ = try call("tincan_reopen_note", ["id": "k3f9"])
        #expect(try store.note(matching: "k3f9").status == .open)
    }

    @Test("reopening takes a reason, the list says why a note came back, and the note shows its history")
    func reopening() throws {
        try store.save(NoteStoreTests.note("20260101-000000-k3f9"))
        try store.save(NoteStoreTests.note("20260101-000001-m4n5", at: 1))
        _ = try call("tincan_resolve_note", ["id": "k3f9", "summary": "Widened the column"])
        _ = try call("tincan_reopen_note", ["id": "k3f9", "reason": "Still clipped"])
        let list = try call("tincan_list_notes")
        let notes = try #require((list["structuredContent"] as? [String: Any])?["notes"] as? [[String: Any]])
        #expect(notes.first { $0["id"] as? String == "20260101-000000-k3f9" }?["reopened_because"] as? String == "Still clipped")
        #expect(notes.first { $0["id"] as? String == "20260101-000001-m4n5" }?["reopened_because"] is NSNull)
        let detail = texts(try call("tincan_get_note", ["id": "k3f9", "include_images": false]))[0]
        #expect(detail.contains("The fix that did not hold: Widened the column"))
        #expect(detail.contains("History:"))
    }

    @Test("serving reads one message per line, skips blank lines, and answers garbage with a parse error")
    func serving() throws {
        var input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            "not json",
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ]
        var output: [String] = []
        server.serve(readLine: { input.isEmpty ? nil : input.removeFirst() }, write: { output.append($0) })
        #expect(output.count == 3)
        #expect(output.allSatisfy { !$0.contains("\n") })
        #expect(output[1].contains("-32700"))
        #expect(output[2] == #"{"id":2,"jsonrpc":"2.0","result":{}}"# || output[2].contains(#""result":{}"#))
    }
}
