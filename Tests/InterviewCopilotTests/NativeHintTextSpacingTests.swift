import AppKit
import Testing
@testable import InterviewCopilot

@MainActor
struct NativeHintTextSpacingTests {
    @Test func proseParagraphSeparatorsUseCompactVerticalSpace() {
        let attributed = HintTextFormatting.attributed("**Краткий ответ**\n\nПервый абзац.\n\n## Объяснение\n\nВторой абзац с `async`.", fontSize: 17)
        let layout = layout(attributed)
        for (previous, next) in [("Краткий ответ", "Первый абзац."), ("Первый абзац.", "Объяснение"), ("Объяснение", "Второй абзац")] {
            let gap = bounds(next, in: layout).minY - bounds(previous, in: layout).maxY
            print("Paragraph gap: \(previous) → \(next): \(gap)")
            #expect(gap >= 4)
            #expect(gap <= 18)
        }
        #expect(attributed.string == "Краткий ответ\n\nПервый абзац.\n\nОбъяснение\n\nВторой абзац с async.")
    }

    @Test func codeBlockBlankLinesKeepFullLineHeight() {
        let attributed = HintTextFormatting.attributed("```python\nfirst()\n\nsecond()\n```", fontSize: 17)
        let layout = layout(attributed)
        let gap = bounds("second()", in: layout).minY - bounds("first()", in: layout).maxY
        #expect(gap >= 18)
        let range = (attributed.string as NSString).range(of: "second()")
        let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(attributed.string.contains("first()\n\nsecond()"))
    }

    private func layout(_ attributed: NSAttributedString) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 430, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    private func bounds(_ text: String, in layout: (NSTextStorage, NSLayoutManager, NSTextContainer)) -> NSRect {
        let range = (layout.0.string as NSString).range(of: text)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return .zero }
        let glyphs = layout.1.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.1.boundingRect(forGlyphRange: glyphs, in: layout.2)
    }
}
