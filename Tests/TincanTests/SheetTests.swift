import AppKit
import SwiftUI
import Testing

@testable import Tincan

@MainActor
@Suite("A sheet open on the window")
struct SheetTests {
    func parent() -> NSWindow {
        if !NSApplication.shared.isRunning { NSApplication.shared.finishLaunching() }
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 500, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color(red: 0, green: 1, blue: 0).frame(width: 500, height: 400))
        window.orderFrontRegardless()
        return window
    }

    func sheet(on window: NSWindow, _ content: NSView) -> NSWindow {
        let sheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 160), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = content
        window.beginSheet(sheet)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return sheet
    }

    @Test("a click on a sheet's control reaches the control, not the window behind the sheet")
    func pointingIntoASheet() throws {
        let window = parent()
        defer { window.close() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
        let button = NSButton(title: "Not Now", target: nil, action: nil)
        button.frame = CGRect(x: 90, y: 60, width: 120, height: 32)
        content.addSubview(button)
        let sheet = sheet(on: window, content)
        defer { window.endSheet(sheet) }
        try #require(window.attachedSheet === sheet)
        let point = sheet.convertPoint(toScreen: CGPoint(x: 150, y: 76))
        #expect(ElementReader.front(at: point, in: window) === sheet)
        #expect(ElementReader.hit(at: point, in: window)?.element.summary == "Button “Not Now”")
        #expect(ElementReader.chain(at: point, in: window).first?.element.role == "AXButton")
        let outside = CGPoint(x: window.frame.minX + 10, y: window.frame.minY + 10)
        #expect(ElementReader.front(at: outside, in: window) === window)
    }

    @Test("the window's picture shows the sheet over it", .enabled(if: Screen.isLive, "Needs an unlocked, awake screen"))
    func pictureIncludesTheSheet() throws {
        let window = parent()
        defer { window.close() }
        let sheet = sheet(on: window, NSHostingView(rootView: Color(red: 1, green: 0, blue: 1).frame(width: 300, height: 160)))
        defer { window.endSheet(sheet) }
        let shot = try #require(WindowCapture.ownWindow(window))
        #expect(abs(CGFloat(shot.image.width) - window.frame.width * shot.scale) <= 1)
        let middle = CGPoint(x: sheet.frame.midX - window.frame.minX, y: window.frame.maxY - sheet.frame.midY)
        let pixel = try #require(NSBitmapImageRep(cgImage: shot.image)
            .colorAt(x: Int(middle.x * shot.scale), y: Int(middle.y * shot.scale))?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent > 0.8 && pixel.greenComponent < 0.5 && pixel.blueComponent > 0.8)
    }
}
