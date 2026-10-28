import AppKit
import SwiftUI
import Testing

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
}
