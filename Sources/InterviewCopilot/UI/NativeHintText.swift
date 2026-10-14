import AppKit
import SwiftUI

struct NativeHintText: NSViewRepresentable {
    var text: String
    var fontSize: Double
    var cardID: UUID?
    var onRendered: (UUID, Double) -> Void

    func makeNSView(context: Context) -> HintTextView {
        let view = HintTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        return view
    }

    func updateNSView(_ view: HintTextView, context: Context) {
        view.cardID = cardID
        view.onRendered = onRendered
        let attributed = HintTextFormatting.attributed(text, fontSize: fontSize)
        if view.textStorage?.isEqual(to: attributed) != true {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(attributed)
            view.setSelectedRange(NSRange(location: min(selection.location, attributed.length), length: min(selection.length, max(0, attributed.length - selection.location))))
            view.invalidateIntrinsicContentSize()
            view.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HintTextView, context: Context) -> CGSize? {
        let candidate = proposal.width ?? (nsView.bounds.width > 0 ? nsView.bounds.width : 580)
        let width = candidate.isFinite ? max(0, candidate) : 580
        if width == 0 { return CGSize(width: 0, height: 24) }
        let storage = NSTextStorage(attributedString: nsView.attributedString())
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(24, ceil(manager.usedRect(for: container).height) + 2))
    }
}

@MainActor
enum HintTextFormatting {
    static func attributed(_ text: String, fontSize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var code = false
        var listIndents = [0]
        let lines = displayLines(text)
        for (index, original) in lines.enumerated() {
            if original.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.toggle(); continue }
            var line = original
            let paragraph = NSMutableParagraphStyle()
            if code {
                paragraph.lineSpacing = fontSize * 0.12
            } else {
                paragraph.minimumLineHeight = fontSize * 1.5
                paragraph.maximumLineHeight = fontSize * 1.5
            }
            paragraph.paragraphSpacing = 4
            paragraph.lineBreakMode = code ? .byCharWrapping : .byWordWrapping
            var font = code ? NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) : NSFont.systemFont(ofSize: fontSize)
            if !code, line.trimmingCharacters(in: .whitespaces).isEmpty {
                font = NSFont.systemFont(ofSize: 4)
                paragraph.lineSpacing = 0
                paragraph.paragraphSpacing = 0
                paragraph.minimumLineHeight = 4
                paragraph.maximumLineHeight = 4
            } else if !code, let marker = ["### ", "## ", "# "].first(where: { line.hasPrefix($0) }) {
                line.removeFirst(marker.count)
                font = NSFont.systemFont(ofSize: fontSize + (marker == "# " ? 2 : 1), weight: .semibold)
                paragraph.paragraphSpacing = 8
            } else if !code, let item = listItem(line) {
                while listIndents.count > 1, item.indent < listIndents.last! { listIndents.removeLast() }
                if item.indent > listIndents.last! { listIndents.append(item.indent) }
                let depth = listIndents.count - 1
                let margin = fontSize + Double(depth) * fontSize * 1.5
                let markerWidth = (item.marker as NSString).size(withAttributes: [.font: font]).width
                let contentIndent = margin + max(fontSize, markerWidth + fontSize * 0.35)
                line = item.marker + "\t" + item.content
                paragraph.firstLineHeadIndent = margin
                paragraph.headIndent = contentIndent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
                paragraph.paragraphSpacing = 2
            } else if !code {
                listIndents = [0]
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 224 / 255, alpha: 1), .paragraphStyle: paragraph]
            let block = NSMutableAttributedString(string: line, attributes: attributes)
            if code { block.addAttribute(.backgroundColor, value: NSColor(white: 0.12, alpha: 1), range: NSRange(location: 0, length: block.length)) }
            else { formatInline(block, fontSize: fontSize) }
            result.append(block)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        return result
    }

    private static let listExpression = try? NSRegularExpression(pattern: #"^([ \t]*)([-*•]|\d+[.)])(?:[ \t]+|$)(.*)$"#)
    private static let numberedLabelStart = try? NSRegularExpression(pattern: #"^([ \t]*)(\d+)[.)][ \t]+(?:\*\*[^*\r\n]+\*\*|__[^_\r\n]+__)"#)
    private static let numberedLabelNext = try? NSRegularExpression(pattern: #"[ \t]+(\d+)[.)][ \t]+(?:\*\*[^*\r\n]+\*\*|__[^_\r\n]+__)"#)

    private static func displayLines(_ text: String) -> [String] {
        var fence: String?
        return text.components(separatedBy: "\n").flatMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                return [line]
            }
            return fence == nil ? splitNumberedLabels(line) : [line]
        }
    }

    private static func splitNumberedLabels(_ line: String) -> [String] {
        let source = line as NSString
        let matching = NSMutableString(string: line)
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if line[cursor] == "\\" {
                cursor = line.index(after: cursor)
                if cursor < line.endIndex { cursor = line.index(after: cursor) }
            } else if line[cursor] == "`" {
                let count = line[cursor...].prefix { $0 == "`" }.count
                let after = line.index(cursor, offsetBy: count)
                let delimiter = String(repeating: "`", count: count)
                let end = line.range(of: delimiter, range: after..<line.endIndex)?.upperBound ?? line.endIndex
                let range = NSRange(cursor..<end, in: line)
                matching.replaceCharacters(in: range, with: String(repeating: "\u{FFFC}", count: range.length))
                cursor = end
            } else { cursor = line.index(after: cursor) }
        }
        guard let first = numberedLabelStart?.firstMatch(in: matching as String, range: NSRange(location: 0, length: source.length)),
              var number = Int(source.substring(with: first.range(at: 2))) else { return [line] }
        let matches = numberedLabelNext?.matches(in: matching as String, range: NSRange(location: NSMaxRange(first.range), length: source.length - NSMaxRange(first.range))) ?? []
        guard !matches.isEmpty else { return [line] }
        for match in matches {
            guard number < Int.max, Int(source.substring(with: match.range(at: 1))) == number + 1 else { return [line] }
            number += 1
        }
        let indent = source.substring(with: first.range(at: 1))
        var start = 0
        var result: [String] = []
        for match in matches {
            result.append((result.isEmpty ? "" : indent) + source.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range(at: 1).location
        }
        result.append(indent + source.substring(from: start))
        return result
    }

    private static func listItem(_ text: String) -> (indent: Int, marker: String, content: String)? {
        guard let match = listExpression?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let source = text as NSString
        let whitespace = source.substring(with: match.range(at: 1))
        let marker = source.substring(with: match.range(at: 2))
        let indent = whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (indent, ["-", "*", "•"].contains(marker) ? "•" : marker, source.substring(with: match.range(at: 3)))
    }

    private static func formatInline(_ value: NSMutableAttributedString, fontSize: Double) {
        guard value.length > 0 else { return }
        let source = value.string
        let base = value.attributes(at: 0, effectiveRange: nil)
        let result = NSMutableAttributedString(string: "")
        var index = source.startIndex
        var plainStart = index
        var emphasis: String?
        func append(_ text: String, code: Bool = false) {
            guard !text.isEmpty else { return }
            var attributes = base
            if code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                attributes[.backgroundColor] = NSColor(white: 0.12, alpha: 1)
            } else if emphasis != nil {
                attributes[.font] = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, ["*", "_", "`", "\\"].contains(source[next]) {
                    append(String(source[plainStart..<index]))
                    append(String(source[next]))
                    index = source.index(after: next)
                    plainStart = index
                    continue
                }
            }
            if source[index] == "`" {
                append(String(source[plainStart..<index]))
                let start = source.index(after: index)
                let end = source[start...].firstIndex(of: "`") ?? source.endIndex
                append(String(source[start..<end]), code: true)
                index = end == source.endIndex ? end : source.index(after: end)
                plainStart = index
                continue
            }
            if let marker = ["**", "__"].first(where: { source[index...].hasPrefix($0) }), emphasis == nil || emphasis == marker {
                append(String(source[plainStart..<index]))
                emphasis = emphasis == nil ? marker : nil
                index = source.index(index, offsetBy: marker.count)
                plainStart = index
                continue
            }
            index = source.index(after: index)
        }
        append(String(source[plainStart..<source.endIndex]))
        value.setAttributedString(result)
    }

}

@MainActor
final class HintTextView: NSTextView {
    var cardID: UUID?
    var onRendered: ((UUID, Double) -> Void)?
    private var renderedCards: Set<UUID> = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !string.isEmpty, let cardID, !renderedCards.contains(cardID) else { return }
        renderedCards.insert(cardID)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let callback = onRendered
        Task { @MainActor in callback?(cardID, timestamp) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: max(1, newSize.width - textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

struct NativeDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeDragView { NativeDragView() }
    func updateNSView(_ nsView: NativeDragView, context: Context) {}
}

@MainActor
final class NativeDragView: NSView {
    private weak var draggedWindow: NSWindow?
    private var pointerAnchor: NSPoint?
    private var windowAnchor: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let source = window else { return }
        let target = source.parent ?? source
        draggedWindow = target
        let point = screenPoint(event)
        pointerAnchor = point
        windowAnchor = target.frame.origin
        trace("down", event: event, target: target, point: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target = draggedWindow, let pointerAnchor, let windowAnchor else { return }
        let point = screenPoint(event)
        target.setFrameOrigin(NSPoint(x: windowAnchor.x + point.x - pointerAnchor.x, y: windowAnchor.y + point.y - pointerAnchor.y))
        trace("move", event: event, target: target, point: point)
    }

    override func mouseUp(with event: NSEvent) {
        draggedWindow = nil
        pointerAnchor = nil
        windowAnchor = nil
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func trace(_ phase: String, event: NSEvent, target: NSWindow, point: NSPoint) {
        if CommandLine.arguments.contains("--demo"), CommandLine.arguments.contains("--trace-layout") {
            print("UI drag \(phase): eventWindow=\(event.windowNumber), sourceWindow=\(window?.windowNumber ?? -1), targetWindow=\(target.windowNumber), pointer=\(point), origin=\(target.frame.origin)")
        }
    }
}
