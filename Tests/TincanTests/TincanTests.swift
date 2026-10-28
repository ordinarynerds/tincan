import AppKit
import ApplicationServices
import SwiftUI
import Testing
import TincanCore

@testable import Tincan

@Suite("Geometry")
struct GeometryTests {
    @Test("a screen rect becomes points from the window's top left")
    func windowTopLeft() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let element = CGRect(x: 150, y: 700, width: 80, height: 20)
        #expect(Geometry.windowTopLeft(element, in: window) == CGRect(x: 50, y: 80, width: 80, height: 20))
    }

    @Test("a crop gains its margin in pixels and never leaves the image")
    func crop() {
        let size = CGSize(width: 1600, height: 1200)
        #expect(Geometry.cropRect(CGRect(x: 100, y: 100, width: 50, height: 20), margin: 10, scale: 2, imageSize: size)
            == CGRect(x: 180, y: 180, width: 140, height: 80))
        #expect(Geometry.cropRect(CGRect(x: 0, y: 0, width: 50, height: 20), margin: 10, scale: 2, imageSize: size)
            == CGRect(x: 0, y: 0, width: 120, height: 60))
        #expect(Geometry.cropRect(CGRect(x: 5000, y: 0, width: 10, height: 10), margin: 0, scale: 1, imageSize: size) == nil)
    }

    @Test("an element as big as the window is the background, not a target")
    func background() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(Geometry.coversWindow(CGRect(x: 0, y: 0, width: 800, height: 560), windowFrame: window))
        #expect(!Geometry.coversWindow(CGRect(x: 10, y: 10, width: 200, height: 40), windowFrame: window))
    }
}

/// Whether the window server is drawing. While the screen is locked or the display sleeps, windows
/// are neither composited nor given an accessibility tree, so these tests would describe the lock.
enum Screen {
    nonisolated static var isLive: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return !locked && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }
}

@MainActor
@Suite("Finding the element under a point")
struct DescentTests {
    final class Node: NSAccessibilityElement {
        var answersForChildren = true

        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            guard answersForChildren else { return self }
            let children = (accessibilityChildren() as? [Node]) ?? []
            return children.reversed().first { $0.accessibilityFrame().contains(point) }.flatMap { $0.accessibilityHitTest(point) } ?? self
        }

        static func make(_ role: NSAccessibility.Role, _ label: String, _ frame: CGRect, children: [Node] = []) -> Node {
            let node = Node()
            node.setAccessibilityRole(role)
            node.setAccessibilityLabel(label)
            node.setAccessibilityFrame(frame)
            node.setAccessibilityChildren(children)
            children.forEach { $0.setAccessibilityParent(node) }
            return node
        }
    }

    @Test("a container that answers every point with itself is searched through its children")
    func descendsPastSelfAnsweringContainer() {
        let find = Node.make(.button, "Find Space", CGRect(x: 100, y: 100, width: 120, height: 30))
        let other = Node.make(.button, "Stop", CGRect(x: 300, y: 100, width: 80, height: 30))
        let row = Node.make(.group, "Row", CGRect(x: 0, y: 80, width: 400, height: 70), children: [find, other])
        let scroll = Node.make(.scrollArea, "Scroll", CGRect(x: 0, y: 0, width: 400, height: 300), children: [row])
        scroll.answersForChildren = false
        #expect(ElementReader.deepest(at: CGPoint(x: 150, y: 110), from: scroll) === find)
        #expect(ElementReader.deepest(at: CGPoint(x: 320, y: 110), from: scroll) === other)
    }

    @Test("a point over no child stays on the container, so empty space is never given a stranger's name")
    func emptySpaceStaysOnContainer() {
        let find = Node.make(.button, "Find Space", CGRect(x: 100, y: 100, width: 120, height: 30))
        let scroll = Node.make(.scrollArea, "Scroll", CGRect(x: 0, y: 0, width: 400, height: 300), children: [find])
        scroll.answersForChildren = false
        #expect(ElementReader.deepest(at: CGPoint(x: 20, y: 250), from: scroll) === scroll)
    }

    @Test("where children overlap, the one drawn last, in front, is chosen")
    func frontMostChildWins() {
        let back = Node.make(.image, "Back", CGRect(x: 0, y: 0, width: 200, height: 200))
        let front = Node.make(.button, "Front", CGRect(x: 50, y: 50, width: 100, height: 100))
        let scroll = Node.make(.scrollArea, "Scroll", CGRect(x: 0, y: 0, width: 400, height: 300), children: [back, front])
        scroll.answersForChildren = false
        #expect(ElementReader.deepest(at: CGPoint(x: 100, y: 100), from: scroll) === front)
    }
}

@MainActor
@Suite("Every layer from the innermost out")
struct LayerTests {
    typealias Node = DescentTests.Node

    @Test("the chain runs from the innermost element out to the window, folding ancestors that only repeat a frame")
    func chainRunsOutward() {
        let label = Node.make(.staticText, "Temporary files in 5 folders", CGRect(x: 160, y: 120, width: 200, height: 16))
        let row = Node.make(.button, "Temporary App Files", CGRect(x: 20, y: 100, width: 600, height: 48), children: [label])
        let wrapper = Node.make(.group, "", CGRect(x: 20, y: 100, width: 600, height: 48), children: [row])
        let section = Node.make(.group, "Can Be Replaced", CGRect(x: 20, y: 80, width: 600, height: 200), children: [wrapper])
        let root = Node.make(.group, "", CGRect(x: 0, y: 0, width: 800, height: 600), children: [section])
        _ = root
        let chain = ElementReader.chain(from: label, windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(chain.map(\.element.label) == ["Temporary files in 5 folders", "Temporary App Files", "Can Be Replaced"])
        #expect(chain[1].hasParts)
        #expect(!chain[0].hasParts)
    }


    @Test("a line read from the screen is placed in window points from the top left")
    func visionBoxToWindow() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 50)
        let rect = ScreenText.windowRect(box: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4), in: frame)
        #expect(rect == CGRect(x: 200, y: 220, width: 200, height: 20))
    }

    @Test("the line chosen is the smallest one under the point")
    func smallestLineWins() {
        let lines = [
            ScreenText.Line(text: "Temporary App Files", rect: CGRect(x: 0, y: 0, width: 200, height: 20)),
            ScreenText.Line(text: "0.6 GB", rect: CGRect(x: 400, y: 0, width: 50, height: 20)),
        ]
        #expect(ScreenText.line(at: CGPoint(x: 420, y: 10), in: lines)?.text == "0.6 GB")
        #expect(ScreenText.line(at: CGPoint(x: 300, y: 10), in: lines) == nil)
    }

    @Test("text drawn into a picture is read back line by line, with where each line is")
    func readsLinesFromPixels() throws {
        let width = 900, height = 120
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
        NSAttributedString(string: "Temporary App Files", attributes: attributes).draw(at: CGPoint(x: 20, y: 60))
        NSAttributedString(string: "0.6 GB", attributes: attributes).draw(at: CGPoint(x: 700, y: 60))
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        let found = ScreenText.recognize(image)
        let texts = found.map(\.text)
        #expect(texts.contains("Temporary App Files"))
        #expect(texts.contains("0.6 GB"))
        let size = try #require(found.first { $0.text == "0.6 GB" })
        #expect(size.box.minX > 0.7)
    }
}

@MainActor
@Suite("Reading a real window", .serialized)
struct WindowTests {
    struct Sample: View {
        var body: some View {
            VStack(spacing: 30) {
                Button("Save Changes") {}
                Text("76 GB").accessibilityIdentifier("size.value")
            }
            .frame(width: 400, height: 300)
        }
    }

    /// SwiftUI builds its accessibility tree when a client first asks, and answers on the main run
    /// loop, so the question is asked from another thread while this one runs the loop.
    func wakeAccessibility() {
        if !NSApplication.shared.isRunning { NSApplication.shared.finishLaunching() }
        let pid = ProcessInfo.processInfo.processIdentifier
        Thread.detachNewThread {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXFocusedWindow" as CFString, &value)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    @Test("an AppKit button is read by its role and title")
    func appKitButton() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let button = NSButton(title: "Empty Trash", target: nil, action: nil)
        button.frame = CGRect(x: 140, y: 130, width: 120, height: 32)
        button.setAccessibilityIdentifier("trash.empty")
        container.addSubview(button)
        let window = window(container)
        defer { window.close() }
        let point = window.convertPoint(toScreen: CGPoint(x: 200, y: 146))
        let hit = ElementReader.hit(at: point, in: window)
        #expect(hit?.element.role == "AXButton")
        #expect(hit?.element.identifier == "trash.empty")
        #expect(hit?.element.summary == "Button “Empty Trash”")
    }

    @Test("the view under a SwiftUI click is named by its hosting view")
    func swiftUIViewName() {
        let window = window(NSHostingView(rootView: Sample()))
        defer { window.close() }
        let name = ElementReader.viewName(at: CGPoint(x: window.frame.midX, y: window.frame.midY), in: window)
        #expect(name?.hasPrefix("NSHostingView<") == true)
    }

    @Test("a window draws itself at its backing scale, and the crop and outline keep their sizes")
    func capture() throws {
        let window = window(NSHostingView(rootView: Sample()))
        defer { window.close() }
        let shot = try #require(WindowCapture.drawn(window))
        #expect(CGFloat(shot.image.width) == window.frame.width * shot.scale)
        let crop = try #require(WindowCapture.crop(shot, to: CGRect(x: 50, y: 50, width: 100, height: 40), margin: 10))
        #expect(CGFloat(crop.width) == 120 * shot.scale)
        let outlined = try #require(WindowCapture.outlined(shot, rect: CGRect(x: 50, y: 50, width: 100, height: 40)))
        #expect(outlined.width == shot.image.width)
        #expect(WindowCapture.png(crop)?.isEmpty == false)
    }

    @Test("a button inside a SwiftUI scroll view is reached, though the scroll view answers for itself", .enabled(if: Screen.isLive, "Needs an unlocked, awake screen"))
    func swiftUIScrollContent() throws {
        let content = ScrollView {
            Button("Find Space") {}
                .frame(width: 200, height: 60)
                .padding(.top, 120)
        }
        .frame(width: 400, height: 300)
        let window = window(NSHostingView(rootView: content))
        defer { window.close() }
        wakeAccessibility()
        let buttons = AccessibilityCheck.elements(in: window).filter { ElementReader.string($0, "accessibilityRole") == "AXButton" }
        let button = try #require(buttons.first)
        let frame = try #require(ElementReader.frame(of: button))
        let hit = try #require(ElementReader.hit(at: CGPoint(x: frame.midX, y: frame.midY), in: window))
        #expect(hit.element.role == "AXButton")
        #expect(hit.element.summary.contains("Find Space"))
    }

    @Test("the check counts an element as reachable only when pointing at it reaches it", .enabled(if: Screen.isLive, "Needs an unlocked, awake screen"))
    func checkReportsReachability() throws {
        let content = ScrollView {
            VStack(spacing: 20) {
                Button("First") {}
                Button("Second") {}
                Button {} label: { Image(systemName: "gear") }
            }
            .padding(40)
        }
        .frame(width: 400, height: 300)
        let window = window(NSHostingView(rootView: content))
        defer { window.close() }
        wakeAccessibility()
        let result = AccessibilityCheck.findings(in: window, ignoring: [])
        #expect(result.checked >= 3)
        #expect(result.findings.filter { $0.kind == .unreachable }.isEmpty)
        #expect(result.findings.contains { $0.kind == .unlabelled } == false)
    }

    @Test("without Screen Recording the picture is the window's own pixels, so what SwiftUI draws is in it", .enabled(if: Screen.isLive, "Needs an unlocked, awake screen"))
    func ownWindowCaptureKeepsSwiftUI() throws {
        let window = window(NSHostingView(rootView: Color(red: 1, green: 0, blue: 1).frame(width: 400, height: 300)))
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let shot = try #require(WindowCapture.ownWindow(window))
        #expect(abs(CGFloat(shot.image.width) - window.frame.width * shot.scale) <= 1)
        let middle = try #require(NSBitmapImageRep(cgImage: shot.image).colorAt(x: shot.image.width / 2, y: shot.image.height / 2))
        let rgb = try #require(middle.usingColorSpace(.sRGB))
        #expect(rgb.redComponent > 0.8 && rgb.greenComponent < 0.5 && rgb.blueComponent > 0.8)
    }
}

@MainActor
@Suite("Working without the keyboard")
struct PointerOnlyTests {
    @Test("a shortcut reads the way a Mac menu writes it")
    func shortcutText() {
        #expect(Tincan.Shortcut.default.displayString == "⌃⌥⌘T")
        #expect(Tincan.Shortcut(key: "R", modifiers: [.command, .shift]).displayString == "⇧⌘R")
    }

    @Test("clicks reach the app while ⌥ is held or Use App is chosen, and never while a note is open")
    func passThrough() {
        #expect(!ReviewSession.passesThrough(optionHeld: false, usingApp: false, composing: false))
        #expect(ReviewSession.passesThrough(optionHeld: true, usingApp: false, composing: false))
        #expect(ReviewSession.passesThrough(optionHeld: false, usingApp: true, composing: false))
        #expect(!ReviewSession.passesThrough(optionHeld: true, usingApp: true, composing: true))
    }

    @Test("the bar starts centred below the menu bar, and a saved spot off every screen is not used")
    func barPosition() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 820)
        #expect(FloatingBar.defaultOrigin(size: CGSize(width: 240, height: 34), visibleFrame: visible) == CGPoint(x: 600, y: 854))
        #expect(FloatingBar.isOnScreen(CGRect(x: 100, y: 100, width: 240, height: 34), screens: [visible]))
        #expect(!FloatingBar.isOnScreen(CGRect(x: 1300, y: 100, width: 240, height: 34), screens: [visible]))
        #expect(FloatingBar.isOnScreen(
            CGRect(x: 1500, y: 100, width: 240, height: 34),
            screens: [visible, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]))
    }

    @Test("the notes menu offers the same items wherever it opens, newest notes numbered as pins are")
    func notesMenu() throws {
        let store = NoteStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("tincan-menu-\(UUID().uuidString)"))
        for index in 0..<10 {
            try store.save(Note(
                id: "20260101-0000\(String(format: "%02d", index))-aaaa", created: Date(timeIntervalSince1970: Double(index)),
                text: "Note \(index)", app: .init(bundleID: nil, name: "Example", version: nil, build: nil), context: [:],
                window: .init(title: "Main", identifier: nil, size: .init(width: 800, height: 600), scale: 2),
                target: .init(kind: .region, rect: .init(x: 0, y: 0, width: 10, height: 10))))
        }
        let menu = NSMenu()
        NotesMenu.populate(menu, store: store, shortcut: .default)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.first == "Start Review Mode")
        #expect(titles.contains("10 open notes"))
        #expect(titles.contains("3. Note 2"))
        #expect(!titles.contains("2. Note 1"))
        #expect(titles.suffix(2) == ["Copy “tincan list” for Your Agent", "Show Notes in Finder"])
    }
}

@MainActor
@Suite("Spots and sending")
struct SpotAndSendTests {
    @Test("a click with nothing under it notes a 48 point square that stays inside the window")
    func spot() {
        let size = CGSize(width: 800, height: 600)
        #expect(Geometry.spot(around: CGPoint(x: 400, y: 300), within: size) == CGRect(x: 376, y: 276, width: 48, height: 48))
        #expect(Geometry.spot(around: CGPoint(x: 5, y: 590), within: size) == CGRect(x: 0, y: 552, width: 48, height: 48))
        #expect(Geometry.spot(around: CGPoint(x: 10, y: 10), within: CGSize(width: 30, height: 20)) == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test("the menu says who is listening, in plain words")
    func listening() {
        let until = Date.distantFuture
        #expect(NotesMenu.listening([]) == "No agent is listening")
        #expect(NotesMenu.listening([Listener(name: "Claude", state: .waiting, until: until)]) == "Claude is listening")
        #expect(NotesMenu.listening(["Claude", "Codex", "Cursor"].map { Listener(name: $0, state: .waiting, until: until) })
            == "Claude, Codex and Cursor are listening")
    }

    @Test("the send switch never promises more than the listener is doing")
    func sendLabel() {
        #expect(ComposerSend.sendLabel(Listener(name: "Claude", state: .waiting, until: .distantFuture)) == "Send to Claude now")
        #expect(ComposerSend.sendLabel(Listener(name: "Claude", state: .working, until: .distantFuture))
            == "Send to Claude, next after the note it is on")
    }
}

@MainActor
@Suite("Opening a note again")
struct OpeningNotesTests {
    let store = NoteStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("tincan-open-\(UUID().uuidString)"))

    func note(_ id: String, window: String = "Main") -> Note {
        Note(
            id: id, created: Date(timeIntervalSince1970: 0), text: "Too tight",
            app: .init(bundleID: nil, name: "Example", version: nil, build: nil), context: ["screen": "Storage"],
            window: .init(title: window, identifier: nil, size: .init(width: 800, height: 600), scale: 2),
            target: .init(kind: .region, rect: .init(x: 0, y: 0, width: 10, height: 10)))
    }

    @Test("a pin says what it holds, who has it and what a click does")
    func pinBanner() {
        func pin(_ kind: OverlayView.Pin.Kind, placement: PinLocator.Placement = .here, agent: OverlayView.Pin.Agent? = nil) -> OverlayView.Pin {
            OverlayView.Pin(
                kind: kind, noteID: "a", text: "Too tight", center: .zero, target: .zero,
                targetSummary: "Button “Save”", placement: placement, agent: agent)
        }
        #expect(pin(.open(number: 2)).banner == "Note 2: Too tight    Click to open, right-click for more.")
        #expect(pin(.open(number: 2), agent: .working("Claude")).banner
            == "Note 2: Too tight    Claude is on it.    Click to open, right-click for more.")
        #expect(pin(.open(number: 2), agent: .waiting("Claude")).banner.contains("Waiting for Claude."))
        #expect(pin(.open(number: 1), placement: .missing).banner.contains("Can’t find Button “Save” here any more."))
        #expect(pin(.toCheck(summary: "Widened it")).banner == "Fixed: Too tight    Widened it.    Click to check it.")
        #expect(pin(.resolved(summary: "")).banner == "Resolved: Too tight    Click to reopen.")
        #expect(pin(.resolved(summary: "")).isResolved)
    }

    @Test("the sheet names the window and the app's context, and a note's age, edits and agent")
    func header() throws {
        #expect(ReviewSession.place(window: "Plumby", context: ["screen": "Storage", "a": "b"])
            == "In “Plumby”, a: b, screen: Storage")
        #expect(ReviewSession.place(window: "", context: [:]) == "")
        try store.save(note("20260101-000000-aaaa"))
        try store.edit("aaaa", text: "Still too tight", at: Date(timeIntervalSince1970: 3_600))
        try store.send("aaaa", to: "Claude")
        let edited = try store.note(matching: "aaaa")
        #expect(ComposerHeader.facts(edited, now: Date(timeIntervalSince1970: 7_200))
            == "Left 2 h ago, edited 1 h ago, waiting for Claude")
    }

    @Test("an open note offers edit and resolve, a resolved one reopen, and both copy and delete")
    func actions() throws {
        try store.save(note("20260101-000000-aaaa", window: "Nowhere"))
        let open = NotesMenu.actions(for: try store.note(matching: "aaaa"), store: store)
        let openTitles = open.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(openTitles == ["Edit Note…", "Mark as Resolved", "Copy Note ID", "Copy “tincan show aaaa”", "Delete Note"])
        #expect(open[0].isEnabled == false)
        #expect(open[0].toolTip == "“Nowhere” is not open. Open it to see this note at its pin.")
        try store.resolve("aaaa", summary: "Fixed")
        let toCheck = NotesMenu.actions(for: try store.note(matching: "aaaa"), store: store).filter { !$0.isSeparatorItem }.map(\.title)
        #expect(toCheck.prefix(3) == ["Check Fix…", "Looks Right", "Reopen Without a Reason"])
        try store.confirm("aaaa")
        let done = NotesMenu.actions(for: try store.note(matching: "aaaa"), store: store).filter { !$0.isSeparatorItem }.map(\.title)
        #expect(done.prefix(2) == ["Reopen…", "Reopen Without a Reason"])
    }

    @Test("a short id is used only while no other note ends the same way")
    func shortID() throws {
        try store.save(note("20260101-000000-aaaa"))
        #expect(NotesMenu.shortID("20260101-000000-aaaa", store: store) == "aaaa")
        try store.save(note("20260101-000001-aaaa"))
        #expect(NotesMenu.shortID("20260101-000000-aaaa", store: store) == "20260101-000000-aaaa")
    }
}
