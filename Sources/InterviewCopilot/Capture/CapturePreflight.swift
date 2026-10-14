import AppKit
@preconcurrency import ScreenCaptureKit

struct PreflightRow: Codable {
    let kind: String
    let normalPixels: Int
    let protectedPixels: Int
    let restoredPixels: Int
    let passed: Bool
}
struct PreflightResult: Codable {
    let displayID: UInt32
    let os: String
    let date: Date
    let rows: [PreflightRow]
    var passed: Bool { !rows.isEmpty && rows.allSatisfy(\.passed) }
}

@MainActor
private final class CaptureMarkerView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill(); bounds.fill() }
}

@MainActor
enum CapturePreflight {
    static func run(windows: [(String, NSWindow)], displayID: CGDirectDisplayID, includeControl: Bool) async throws -> PreflightResult {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { throw CaptureError.displayMissing }
        let originals = windows.map { (_, window) in (window, window.frame, window.parent, window.delegate) }
        for (window, _, parent, _) in originals { window.delegate = nil; parent?.removeChildWindow(window); window.orderOut(nil) }
        defer {
            for (window, frame, _, delegate) in originals { window.orderOut(nil); window.sharingType = .none; window.setFrame(frame, display: false); window.delegate = delegate }
            for (window, _, parent, _) in originals { if let parent { parent.addChildWindow(window, ordered: .above) } }
        }
        var results: [PreflightRow] = []
        for (kind, window) in windows {
            try Task.checkCancellation()
            let content = window.contentView, frame = window.frame, background = window.backgroundColor, alpha = window.alphaValue, opaque = window.isOpaque, level = window.level
            let parent = window.parent
            parent?.removeChildWindow(window)
            let marker = CaptureMarkerView(frame: NSRect(x: 0, y: 0, width: 260, height: 150))
            window.contentView = marker; window.alphaValue = 1; window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1); window.isOpaque = true; window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.setFrame(NSRect(x: screen.visibleFrame.midX - 130, y: screen.visibleFrame.midY - 75, width: 260, height: 150), display: true)
            defer {
                window.orderOut(nil); window.contentView = content; window.backgroundColor = background; window.alphaValue = alpha; window.isOpaque = opaque; window.level = level
                window.sharingType = .none; window.setFrame(frame, display: false)
                if let parent { parent.addChildWindow(window, ordered: .above) }
            }
            marker.layoutSubtreeIfNeeded()
            let expected = try markerRGB(marker, screen: screen)
            var normal = 0
            if includeControl {
                window.sharingType = .readOnly; window.orderFrontRegardless(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(180))
                normal = try countMarker(try await ScreenshotCapture.image(displayID: displayID, excludeOwnWindows: false), expected: expected)
            }
            window.sharingType = .none; window.orderFrontRegardless(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            let protected = try countMarker(try await ScreenshotCapture.image(displayID: displayID, excludeOwnWindows: false), expected: expected)
            var restored = 0
            if includeControl {
                window.sharingType = .readOnly; window.orderFrontRegardless(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(180))
                restored = try countMarker(try await ScreenshotCapture.image(displayID: displayID, excludeOwnWindows: false), expected: expected)
                window.sharingType = .none
            }
            let passed = normal > 2000 && restored > 2000 && protected < 50
            results.append(PreflightRow(kind: kind, normalPixels: normal, protectedPixels: protected, restoredPixels: restored, passed: passed))
        }
        return PreflightResult(displayID: displayID, os: ProcessInfo.processInfo.operatingSystemVersionString, date: Date(), rows: results)
    }
    private static func markerRGB(_ marker: NSView, screen: NSScreen) throws -> [Int] {
        guard let bitmap = marker.bitmapImageRepForCachingDisplay(in: marker.bounds) else { throw bitmapError() }
        marker.cacheDisplay(in: marker.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let space = screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { throw bitmapError() }
        let bytes = try rgbaBytes(image, space: space)
        let center = (image.height / 2 * image.width + image.width / 2) * 4
        guard bytes[center + 3] > 240 else { throw bitmapError() }
        return [Int(bytes[center]), Int(bytes[center + 1]), Int(bytes[center + 2])]
    }

    private static func rgbaBytes(_ image: CGImage, space: CGColorSpace) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw bitmapError() }
        return bytes
    }

    private static func countMarker(_ image: CGImage, expected: [Int]) throws -> Int {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw bitmapError() }
        let bytes = try rgbaBytes(image, space: space)
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[index]) - expected[0]) < 18 && abs(Int(bytes[index + 1]) - expected[1]) < 18 && abs(Int(bytes[index + 2]) - expected[2]) < 18 { count += 1 }
        }
        return count
    }

    private static func bitmapError() -> NSError { NSError(domain: "CapturePreflight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось откалибровать изображение проверки защиты"]) }
}
