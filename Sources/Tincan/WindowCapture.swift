import AppKit
import ScreenCaptureKit

/// A picture of one window, with any sheet the app has open on it, taken before the note sheet opens
/// so the note sheet is never in it.
///
/// When the app already has Screen Recording permission, ScreenCaptureKit takes the picture exactly
/// as it is on screen. Without it, the window server still hands an app the pixels of its own
/// windows, through `CGWindowListCreateImage`. Last comes asking the window to draw itself, which
/// leaves out everything SwiftUI renders, since SwiftUI draws through layers and not `draw(_:)`.
/// Tincan never asks for the permission itself: a review tool that triggers a privacy prompt in the
/// app under review changes the very thing being reviewed.
@MainActor
enum WindowCapture {
    struct Shot {
        var image: CGImage
        var scale: CGFloat
    }

    static func capture(_ window: NSWindow) async -> Shot? {
        if window.attachedSheet == nil, CGPreflightScreenCaptureAccess(), let shot = await screenCapture(window) { return shot }
        return ownWindow(window) ?? drawn(window)
    }

    private typealias WindowListImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// Swift marks `CGWindowListCreateImage` unavailable from the macOS 15 SDK, in favour of
    /// ScreenCaptureKit, but CoreGraphics still exports it and it is the one call that reads an app's
    /// own window without the permission. It is looked up at run time, so a macOS that drops it
    /// falls through to the drawn picture instead of failing to launch.
    private static let windowListImage: WindowListImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        return unsafeBitCast(symbol, to: WindowListImage.self)
    }()

    static func ownWindow(_ window: NSWindow) -> Shot? {
        guard let create = windowListImage, window.windowNumber > 0 else { return nil }
        if let sheet = frontSheet(of: window) { return withSheet(window, sheet: sheet, create: create) }
        let includingWindow: UInt32 = 1 << 3
        let ignoringFramingAtBestResolution: UInt32 = (1 << 0) | (1 << 3)
        guard let image = create(.null, includingWindow, CGWindowID(window.windowNumber), ignoringFramingAtBestResolution)?
            .takeRetainedValue(), image.width > 1
        else { return nil }
        return Shot(image: image, scale: CGFloat(image.width) / max(window.frame.width, 1))
    }

    private static func frontSheet(of window: NSWindow) -> NSWindow? {
        var front: NSWindow?
        while let sheet = (front ?? window).attachedSheet, sheet.isVisible, sheet.windowNumber > 0 { front = sheet }
        return front
    }

    /// A sheet is a window of its own, so a picture of the window alone shows what is behind the
    /// sheet. The window's rect is taken from the front sheet down, which is the sheet over the window
    /// as the person sees it.
    private static func withSheet(_ window: NSWindow, sheet: NSWindow, create: WindowListImage) -> Shot? {
        let top = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        let bounds = CGRect(
            x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        let onScreenBelowWindow: UInt32 = 1 << 2
        let includingWindow: UInt32 = 1 << 3
        let bestResolution: UInt32 = 1 << 3
        guard let image = create(bounds, onScreenBelowWindow | includingWindow, CGWindowID(sheet.windowNumber), bestResolution)?
            .takeRetainedValue(), image.width > 1
        else { return nil }
        return Shot(image: image, scale: CGFloat(image.width) / max(window.frame.width, 1))
    }

    static func drawn(_ window: NSWindow) -> Shot? {
        guard let frameView = window.contentView?.superview else { return nil }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        return Shot(image: image, scale: CGFloat(image.width) / max(bounds.width, 1))
    }

    static func screenCapture(_ window: NSWindow) async -> Shot? {
        let windowID = CGWindowID(window.windowNumber)
        let size = window.frame.size
        let scale = window.backingScaleFactor
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: configuration)
            return Shot(image: image, scale: scale)
        } catch {
            return nil
        }
    }

    static func crop(_ shot: Shot, to rect: CGRect, margin: CGFloat = 16) -> CGImage? {
        guard let pixels = Geometry.cropRect(
            rect, margin: margin, scale: shot.scale,
            imageSize: CGSize(width: shot.image.width, height: shot.image.height))
        else { return nil }
        return shot.image.cropping(to: pixels)
    }

    /// The whole window with the target outlined, so the picture says where to look on its own.
    static func outlined(_ shot: Shot, rect: CGRect) -> CGImage? {
        let width = shot.image.width
        let height = shot.image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let line = 3 * shot.scale
        let box = CGRect(
            x: rect.minX * shot.scale, y: CGFloat(height) - rect.maxY * shot.scale,
            width: rect.width * shot.scale, height: rect.height * shot.scale
        ).insetBy(dx: -line, dy: -line)
        context.setStrokeColor(Style.accent.cgColor)
        context.setLineWidth(line)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4 * shot.scale, cornerHeight: 4 * shot.scale, transform: nil))
        context.strokePath()
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

@MainActor
enum Style {
    static let accent = NSColor.systemOrange
}
