import AppKit
import SwiftUI
import Testing
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct FencedCodeTests {
    @Test func fencedSourcePreservesUnicodeIndentationAndEmbeddedFenceText() {
        let source = "print(\"ёж 🦔\")\n    # ``` внутри комментария\n\nprint('__init__')\n"
        let segments = HintMarkdownParser.segments("Вступление.\n\n```python\n" + source + "```\n\nИтог.")
        #expect(segments.count == 3)
        guard segments.count == 3, case let .code(block) = segments[1].content else { Issue.record("Fenced code не выделен"); return }
        #expect(block.language == "python")
        #expect(block.source == source)
        #expect(block.isComplete)
        if case let .prose(text) = segments[0].content { #expect(text == "Вступление.\n\n") }
        else { Issue.record("Вступление не сохранено") }
        if case let .prose(text) = segments[2].content { #expect(text == "\nИтог.") }
        else { Issue.record("Заключение не сохранено") }
    }

    @Test func streamedFenceKeepsOneSlotAndWithholdsIncompleteHeader() {
        let prefixes = ["`", "``", "```p", "```python\n", "```python\nprint('да')", "```python\nprint('да')\n```"]
        var ids: [Int] = []
        for (index, text) in prefixes.enumerated() {
            let segments = HintMarkdownParser.segments(text)
            #expect(segments.count == 1)
            guard let segment = segments.first, case let .code(block) = segment.content else { Issue.record("Частичный fence показан как prose"); continue }
            ids.append(segment.id)
            #expect(block.isComplete == (index == prefixes.count - 1))
            if index <= 2 { #expect(block.language.isEmpty); #expect(block.source.isEmpty) }
            if index == 4 { #expect(block.source == "print('да')") }
        }
        #expect(Set(ids).count == 1)
    }

    @Test func longerFenceAndWindowsLineEndingsRemainExact() {
        let source = "value = '```'\r\n```\r\nprint(value)\r\n"
        let segments = HintMarkdownParser.segments("````python\r\n" + source + "````\r\n")
        guard let segment = segments.first, case let .code(block) = segment.content else { Issue.record("Длинный fence не выделен"); return }
        #expect(block.source == source)
        #expect(block.isComplete)
        let inline = HintMarkdownParser.segments("Использую `value` и `__init__`.")
        #expect(inline.count == 1)
        if case let .prose(text) = inline.first?.content { #expect(text == "Использую `value` и `__init__`.") }
        else { Issue.record("Inline code выделен в отдельный блок") }
    }

    @Test func copyWritesOnlyClosedRawSourceToDedicatedPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("до копирования", forType: .string)
        let open = HintCodeBlock(language: "python", source: "print('ёж')", isComplete: false)
        #expect(!open.copy(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "до копирования")
        let closed = HintCodeBlock(language: "python", source: "print('ёж')\n\n", isComplete: true)
        #expect(closed.copy(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "print('ёж')\n\n")
    }

    @Test func syntaxColorsProtectCommentsAndQuotedKeywords() {
        let source = "# return class 42\nlabel = \"return # class\"\ndoc = '''class\nreturn'''\ndef имя():\n    return True\n"
        let attributed = CodeSyntaxFormatting.attributed(source, language: "python", fontSize: 13)
        #expect(attributed.string == source)
        let comment = color("# return class 42", in: attributed)
        #expect(color("return class 42", in: attributed) == comment)
        let quoted = color("\"return # class\"", in: attributed)
        #expect(color("return # class", in: attributed) == quoted)
        let triple = color("'''class", in: attributed)
        #expect(color("return'''", in: attributed) == triple)
        let keyword = color("def", in: attributed)
        #expect(keyword != quoted)
        #expect(keyword != comment)
        #expect(keyword == color("return True", in: attributed))
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 13)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func codeAndLongFollowupsDoNotExpandAnswerViewports() async {
        _ = NSApplication.shared
        let code = "def пример():\n    return \"" + String(repeating: "длинный_идентификатор_", count: 18) + "\"\n"
        for width: CGFloat in [480, 680] {
            let registry = ProtectedWindowRegistry()
            registry.canShow = { _ in true }
            let model = UIModel()
            model.settings.fontSize = 13
            let ui = InterviewUI(model: model, registry: registry)
            defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
            var presentation = UIPresentation()
            presentation.phase = .listening
            presentation.hintStatus = .ready
            presentation.selectedCardID = UUID()
            presentation.question = "Вопрос скрыт до нажатия кнопки"
            presentation.text = "```python\n" + code + "```\n\n**Объяснение:** Обычный текст после кода."
            presentation.followups = [String(repeating: "Как проверить результат на более длинных входных данных? ", count: 4)]
            model.apply(presentation)
            ui.answer.setContentSize(NSSize(width: width, height: 600))
            #expect(ui.showAnswer())
            ui.answer.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            guard let root = ui.answer.contentView, let codeText = descendants(HintTextView.self, in: root).first(where: { $0.identifier?.rawValue == "code-block-text" }) else { Issue.record("Code text не создан"); continue }
            #expect(codeText.string == code)
            guard let container = codeText.textContainer, let manager = codeText.layoutManager else { Issue.record("Code layout не создан"); continue }
            manager.ensureLayout(for: container)
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            #expect(lines == 2)
            #expect(codeText.bounds.width > width)
            #expect(root.bounds.width <= width + 1)
            let proseViews = descendants(HintTextView.self, in: root).filter({ $0.identifier?.rawValue != "code-block-text" })
            #expect(!proseViews.isEmpty)
            for text in proseViews {
                let rect = text.convert(text.bounds, to: root)
                #expect(rect.minX >= 12)
                #expect(rect.maxX <= root.bounds.width - 12 + 1)
            }
            let codeScroll = ancestor(NSScrollView.self, of: codeText)
            #expect(codeScroll != nil)
            if let codeScroll {
                #expect(codeScroll.convert(codeScroll.bounds, to: root).maxX <= root.bounds.width - 12 + 1)
            }
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/copilot-code-layout-\(Int(width)).png"))
                }
            }
        }
    }

    @Test func codeFirstAnswerReportsRealContentDraw() async {
        _ = NSApplication.shared
        let registry = ProtectedWindowRegistry()
        registry.canShow = { _ in true }
        let model = UIModel()
        let ui = InterviewUI(model: model, registry: registry)
        defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
        let card = UUID()
        var renders: [UUID] = []
        model.onContentRendered = { id, _ in renders.append(id) }
        var presentation = UIPresentation()
        presentation.phase = .listening
        presentation.hintStatus = .streaming
        presentation.selectedCardID = card
        presentation.text = "```python\nprint('реальный код')"
        model.apply(presentation)
        #expect(ui.showAnswer())
        ui.answer.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(renders.contains(card))
    }

    private func color(_ text: String, in attributed: NSAttributedString) -> NSColor? {
        let range = (attributed.string as NSString).range(of: text)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func ancestor<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
        guard let parent = view.superview else { return nil }
        return parent as? T ?? ancestor(type, of: parent)
    }

}
