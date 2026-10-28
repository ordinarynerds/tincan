import AppKit
import ScreenCaptureKit

/// A picture of one window, taken before the note sheet opens so the sheet is never in it.
///
/// When the app already has Screen Recording permission, ScreenCaptureKit takes the picture exactly
/// as it is on screen. Otherwise the window draws itself into a bitmap, which needs no permission.
/// Tincan never asks for the permission itself: a review tool that triggers a privacy prompt in the
/// app under review changes the very thing being reviewed.
@MainActor
enum WindowCapture {
    struct Shot {
        var image: CGImage
        var scale: CGFloat
    }

    static func capture(_ window: NSWindow) async -> Shot? {
        if CGPreflightScreenCaptureAccess(), let shot = await screenCapture(window) { return shot }
        return drawn(window)
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
