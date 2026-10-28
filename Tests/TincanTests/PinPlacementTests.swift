import AppKit
import Testing
import TincanCore

@testable import Tincan

@MainActor
@Suite("Pins follow their element", .serialized)
struct PinPlacementTests {
    func window(with button: NSButton) -> NSWindow {
        if !NSApplication.shared.isRunning { NSApplication.shared.finishLaunching() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(button)
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        return window
    }

    func note(at rect: CGRect, element: Note.Element) -> Note {
        Note(
            id: "20260101-000000-aaaa", created: Date(), text: "Wrong colour",
            app: .init(bundleID: nil, name: "Example", version: nil, build: nil),
            window: .init(title: "", identifier: nil, size: .init(width: 400, height: 300), scale: 2),
            target: .init(kind: .element, rect: Geometry.rect(rect), element: element))
    }

    @Test("a pin stays on its element, follows it when it moves, and is marked missing when it is gone")
    func follows() throws {
        let button = NSButton(title: "Empty Trash", target: nil, action: nil)
        button.frame = CGRect(x: 40, y: 200, width: 120, height: 32)
        button.setAccessibilityIdentifier("trash.empty")
        let window = window(with: button)
        defer { window.close() }
        let hit = try #require(ElementReader.hit(at: window.convertPoint(toScreen: CGPoint(x: 100, y: 216)), in: window))
        let recorded = Geometry.windowTopLeft(hit.screenFrame, in: window.frame)
        let note = note(at: recorded, element: hit.element)
        let locator = PinLocator()

        #expect(locator.locate(note, in: window) == .init(rect: recorded, placement: .here))

        button.frame = CGRect(x: 240, y: 40, width: 120, height: 32)
        locator.forget()
        let moved = locator.locate(note, in: window)
        #expect(moved.placement == .moved)
        #expect(moved.rect.minX > recorded.minX + 150)

        button.removeFromSuperview()
        locator.forget()
        #expect(locator.locate(note, in: window) == .init(rect: recorded, placement: .missing))
    }

    @Test("a region has no element to follow, so its pin stays where it was drawn")
    func region() {
        let window = window(with: NSButton(title: "Other", target: nil, action: nil))
        defer { window.close() }
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        var note = note(at: rect, element: .init())
        note.target = .init(kind: .region, rect: Geometry.rect(rect))
        #expect(PinLocator().locate(note, in: window) == .init(rect: rect, placement: .here))
    }

    @Test("an agent shows on a pin only while the note is open: waiting until handed over, then while it works")
    func agentOnPin() {
        var note = note(at: .zero, element: .init())
        #expect(ReviewSession.agent(for: note, listener: nil) == nil)
        note.handoff = .init(agent: "Claude", sent: Date())
        #expect(ReviewSession.agent(for: note, listener: nil) == .waiting("Claude"))
        note.handoff?.delivered = Date()
        let working = Listener(name: "Claude", state: .working, until: .distantFuture)
        #expect(ReviewSession.agent(for: note, listener: working) == .working("Claude"))
        #expect(ReviewSession.agent(for: note, listener: nil) == nil)
        note.status = .resolved
        #expect(ReviewSession.agent(for: note, listener: working) == nil)
    }

    @Test("a row in the notes list says where the note is and what is happening to it")
    func rowMeta() {
        var note = note(at: .zero, element: .init(role: "AXButton", label: "Save"))
        note.created = Date(timeIntervalSince1970: 0)
        note.handoff = .init(agent: "Claude", sent: Date(timeIntervalSince1970: 0), delivered: Date(timeIntervalSince1970: 1))
        let working = Listener(name: "Claude", state: .working, until: .distantFuture)
        #expect(NoteRow.meta(note, listener: working, now: Date(timeIntervalSince1970: 600))
            == "Button “Save”, 10 min ago, Claude is on it")
        note.status = .resolved
        note.resolution = .init(at: Date(timeIntervalSince1970: 300), summary: "Bigger")
        #expect(NoteRow.meta(note, listener: nil, now: Date(timeIntervalSince1970: 600)) == "Button “Save”, fixed 5 min ago: Bigger")
    }
}

@MainActor
@Suite("Configuration")
struct ConfigurationTests {
    @Test("a trailing closure is still the context, with or without a way to navigate")
    func trailingClosureIsContext() {
        let plain = Tincan.Configuration { ["screen": "Settings"] }
        #expect(plain.context() == ["screen": "Settings"])
        #expect(plain.navigate == nil)
        let full = Tincan.Configuration(placeKeys: ["screen"], context: { ["screen": "Home"] }, navigate: { _ in true })
        #expect(full.context() == ["screen": "Home"])
        #expect(full.navigate?([:]) == true)
    }
}
