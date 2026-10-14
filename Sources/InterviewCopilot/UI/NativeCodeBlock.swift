import AppKit
import SwiftUI

struct HintCodeBlock: Equatable {
    var language: String
    var source: String
    var isComplete: Bool

    @MainActor func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard isComplete, !source.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(source, forType: .string)
    }
}

struct HintMarkdownSegment: Identifiable, Equatable {
    enum Content: Equatable {
        case prose(String)
        case code(HintCodeBlock)
    }
    var id: Int
    var content: Content
}

enum HintMarkdownParser {
    static func segments(_ text: String) -> [HintMarkdownSegment] {
        var result: [HintMarkdownSegment] = []
        var prose = ""
        var proseStart = 0
        var open: (id: Int, marker: Character, count: Int, block: HintCodeBlock)?
        var start = text.startIndex
        var offset = 0
        func appendProse() {
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(HintMarkdownSegment(id: proseStart, content: .prose(prose)))
            }
            prose = ""
        }
        while start < text.endIndex {
            let newline = text[start...].firstIndex(where: \.isNewline)
            let end = newline.map { text.index(after: $0) } ?? text.endIndex
            let raw = String(text[start..<end])
            let line = raw.trimmingCharacters(in: .newlines)
            let completeLine = newline != nil
            if var state = open {
                let delimiter = fence(line)
                if let delimiter, delimiter.marker == state.marker, delimiter.count >= state.count, delimiter.info.isEmpty {
                    state.block.isComplete = true
                    result.append(HintMarkdownSegment(id: state.id, content: .code(state.block)))
                    open = nil
                    proseStart = offset + raw.utf16.count
                } else {
                    let tail = line.trimmingCharacters(in: .whitespaces)
                    let partialClosing = !completeLine && !tail.isEmpty && tail.allSatisfy { $0 == state.marker } && tail.count < state.count
                    if !partialClosing { state.block.source += raw }
                    open = state
                }
            } else if let delimiter = fence(line) {
                appendProse()
                let language = completeLine ? String(delimiter.info.split(whereSeparator: \.isWhitespace).first ?? "") : ""
                open = (offset, delimiter.marker, delimiter.count, HintCodeBlock(language: language, source: "", isComplete: false))
            } else if !completeLine, partialFence(line) {
                appendProse()
                let marker = line.trimmingCharacters(in: .whitespaces).first!
                open = (offset, marker, 3, HintCodeBlock(language: "", source: "", isComplete: false))
            } else {
                if prose.isEmpty { proseStart = offset }
                prose += raw
            }
            offset += raw.utf16.count
            start = end
        }
        if let open { result.append(HintMarkdownSegment(id: open.id, content: .code(open.block))) }
        appendProse()
        return result
    }

    private static func fence(_ line: String) -> (marker: Character, count: Int, info: String)? {
        let prefix = line.prefix { $0 == " " }
        guard prefix.count <= 3 else { return nil }
        let body = line.dropFirst(prefix.count)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let count = body.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        return (marker, count, String(body.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }

    private static func partialFence(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: .whitespaces)
        guard let marker = body.first, marker == "`" || marker == "~" else { return false }
        return body.count < 3 && body.allSatisfy { $0 == marker }
    }
}

@MainActor
enum CodeSyntaxFormatting {
    static func attributed(_ text: String, language: String, fontSize: Double) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * 1.5
        paragraph.maximumLineHeight = fontSize * 1.5
        paragraph.lineBreakMode = .byClipping
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 224 / 255, alpha: 1), .paragraphStyle: paragraph])
        let name = language.lowercased()
        let python = ["python", "py", "python3"].contains(name)
        let supported = python || ["javascript", "js", "typescript", "ts", "jsx", "tsx", "swift", "json", "bash", "sh", "shell", "sql"].contains(name)
        guard supported else { return result }
        let strings = #"""
        (?:[rRuUbBfF]{0,2})(?s:""".*?(?:"""|$)|'''.*?(?:'''|$))|"(?:\\.|[^"\\\r\n])*(?:"|(?=\r?\n|$))|'(?:\\.|[^'\\\r\n])*(?:'|(?=\r?\n|$))|`(?:\\.|[^`\\])*(?:`|$)
        """#
        let comments = python || ["bash", "sh", "shell"].contains(name) ? #"#[^\r\n]*"# : #"//[^\r\n]*|(?s:/\*.*?(?:\*/|$))|--[^\r\n]*"#
        let tokens = strings + "|" + comments + #"|\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b|[\p{L}_][\p{L}\p{N}_]*"#
        guard let expression = try? NSRegularExpression(pattern: tokens) else { return result }
        let keywords: Set<String> = python
            ? ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
            : ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "export", "extends", "for", "from", "func", "function", "if", "import", "in", "interface", "let", "new", "of", "public", "return", "static", "struct", "switch", "throw", "try", "type", "var", "while", "yield", "select", "where", "join", "on", "group", "by", "order", "limit", "insert", "into", "values", "update", "set", "delete"]
        var definition = false
        for match in expression.matches(in: text, range: NSRange(location: 0, length: result.length)) {
            let token = (text as NSString).substring(with: match.range)
            let comment = token.hasPrefix("#") || token.hasPrefix("//") || token.hasPrefix("/*") || token.hasPrefix("--")
            let quoted = token.contains("\"") || token.contains("'") || token.hasPrefix("`")
            let color: NSColor?
            if comment {
                color = NSColor(red: 0.56, green: 0.64, blue: 0.69, alpha: 1)
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: match.range)
            } else if quoted {
                color = NSColor(red: 0.76, green: 0.84, blue: 0.49, alpha: 1)
            } else if keywords.contains(python ? token : token.lowercased()) {
                color = NSColor(red: 0.80, green: 0.58, blue: 0.95, alpha: 1)
                definition = ["class", "def", "func", "function"].contains(token)
            } else if ["True", "False", "None", "true", "false", "null", "nil"].contains(token) || token.first?.isNumber == true {
                color = NSColor(red: 0.46, green: 0.79, blue: 0.90, alpha: 1)
            } else if definition {
                color = NSColor(red: 0.95, green: 0.79, blue: 0.40, alpha: 1)
                definition = false
            } else { color = nil }
            if let color { result.addAttribute(.foregroundColor, value: color, range: match.range) }
        }
        return result
    }

    static func size(_ attributed: NSAttributedString, fontSize: Double) -> NSSize {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: ceil(used.width) + 2, height: max(fontSize * 1.5, ceil(used.height)))
    }
}

struct NativeHintContent: View {
    var text: String
    var fontSize: Double
    var cardID: UUID?
    var onRendered: (UUID, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(HintMarkdownParser.segments(text)) { segment in
                switch segment.content {
                case .prose(let prose):
                    NativeHintText(text: prose.trimmingCharacters(in: .newlines), fontSize: fontSize, cardID: cardID, onRendered: onRendered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let block):
                    NativeCodeBlock(block: block, fontSize: fontSize, cardID: cardID, onRendered: onRendered)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeCodeBlock: View {
    var block: HintCodeBlock
    var fontSize: Double
    var cardID: UUID?
    var onRendered: (UUID, Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(block.language.isEmpty ? "Код" : block.language).font(.system(size: 11, weight: .medium)).foregroundStyle(UITheme.muted)
                Spacer(minLength: 4)
                Button { _ = block.copy() } label: { Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 24, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(UITheme.accentText).disabled(!block.isComplete || block.source.isEmpty)
                    .accessibilityLabel("Копировать код").help(block.isComplete ? "Копировать код" : "Код ещё генерируется")
            }.padding(.horizontal, 12).frame(height: 30).background(Color.white.opacity(0.035))
            NativeCodeViewport(block: block, fontSize: fontSize, cardID: cardID, onRendered: onRendered)
                .frame(maxWidth: .infinity)
        }.background(Color(white: 0.09)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(UITheme.border, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeCodeViewport: NSViewRepresentable {
    var block: HintCodeBlock
    var fontSize: Double
    var cardID: UUID?
    var onRendered: (UUID, Double) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let text = HintTextView(frame: .zero)
        text.identifier = NSUserInterfaceItemIdentifier("code-block-text")
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? HintTextView else { return }
        text.cardID = cardID
        text.onRendered = onRendered
        let attributed = CodeSyntaxFormatting.attributed(block.source, language: block.language, fontSize: fontSize)
        if text.textStorage?.isEqual(to: attributed) != true { text.textStorage?.setAttributedString(attributed) }
        let size = CodeSyntaxFormatting.size(attributed, fontSize: fontSize)
        text.setFrameSize(NSSize(width: max(scroll.contentSize.width, size.width + 24), height: size.height + 24))
        text.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let attributed = CodeSyntaxFormatting.attributed(block.source, language: block.language, fontSize: fontSize)
        let size = CodeSyntaxFormatting.size(attributed, fontSize: fontSize)
        return CGSize(width: proposal.width ?? 580, height: size.height + 24)
    }
}
