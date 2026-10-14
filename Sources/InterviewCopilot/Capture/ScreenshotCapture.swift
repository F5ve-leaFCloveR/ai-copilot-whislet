import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
enum ScreenshotCapture {
    static func image(displayID: CGDirectDisplayID, excludeOwnWindows: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayMissing }
        let own = excludeOwnWindows ? content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier } : []
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width; configuration.height = display.height
        configuration.showsCursor = false; configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
    static func capture(displayID: CGDirectDisplayID) async throws -> Data {
        let image = try await image(displayID: displayID, excludeOwnWindows: true)
        let ratio = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.invalidAudio }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(), let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { throw CaptureError.invalidAudio }
        return data
    }
    static func needsScreenReference(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["на экране", "этот код", "эту схему", "смотри схему", "посмотри на", "on screen", "this code", "this diagram", "look at the"].contains { lower.contains($0) }
    }
}
