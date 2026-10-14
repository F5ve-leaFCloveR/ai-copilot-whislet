import AppKit
import Testing
@testable import InterviewCopilot

@MainActor
struct NativeHintTextTypographyTests {
    @Test func mergedNumberedLabelsRenderAsSeparateCompactParagraphs() {
        let text = "1. **Длина контекста** — модель должна уверенно вмещать исходные документы и запрос, часто от восьми тысяч токенов и выше. 2. **Точность следования** — способность модели опираться строго на переданные фрагменты без галлюцинаций. 3. **Latency и скорость** — приемлемое время ответа для пользователя, особенно при потоковой выдаче. 4. **Стоимость запуска** — баланс между закрытыми API и затратами на хостинг open-source моделей. 5. **Инструкции и формат** — надежное следование системному промпту и вывод в JSON при необходимости."
        let attributed = HintTextFormatting.attributed(text, fontSize: 13)
        let paragraphs = attributed.string.components(separatedBy: "\n")
        let titles = ["Длина контекста", "Точность следования", "Latency и скорость", "Стоимость запуска", "Инструкции и формат"]
        #expect(paragraphs.count == 5)
        for (index, title) in titles.enumerated() {
            guard index < paragraphs.count else { continue }
            #expect(paragraphs[index].hasPrefix("\(index + 1).\t\(title) — "))
            let range = (attributed.string as NSString).range(of: title)
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.minimumLineHeight == 19.5)
            #expect(style?.paragraphSpacing == 2)
            #expect(font(title, in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .semibold).fontName)
        }
    }

    @Test func mergedListIgnoresInlineCodeNumericValuesAndNonSequentialLabels() {
        let text = "1. **Первое** — сохраняю `2. **literal**` и значение 2.5. 2. **Второе** — конец."
        let attributed = HintTextFormatting.attributed(text, fontSize: 13)
        #expect(attributed.string == "1.\tПервое — сохраняю 2. **literal** и значение 2.5.\n2.\tВторое — конец.")
        #expect(font("2. **literal**", in: attributed)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let adjacentCode = HintTextFormatting.attributed("1. **Первое** — `value` 2. **Второе** — конец.", fontSize: 13)
        #expect(adjacentCode.string == "1.\tПервое — value\n2.\tВторое — конец.")
        let plain = HintTextFormatting.attributed("Версии 1. **Начальная** и 2. **Следующая** сравниваются отдельно.", fontSize: 13)
        #expect(!plain.string.contains("\n"))
        let skipped = HintTextFormatting.attributed("1. **Первое** — описание. 3. **Третье** — не последовательный список.", fontSize: 13)
        #expect(!skipped.string.contains("\n"))
        let code = HintTextFormatting.attributed("```python\n1. **Первое** — literal. 2. **Второе** — literal.\n```", fontSize: 13)
        #expect(code.string.contains("1. **Первое** — literal. 2. **Второе** — literal."))
        #expect(!code.string.contains("literal.\n2."))
    }

    @Test func wrappedProseUsesOneAndAHalfLineHeightAtThirteenPoints() {
        let attributed = HintTextFormatting.attributed("Сначала измерю recall на размеченных вопросах, затем сравню hybrid search и проверю, что релевантные документы появляются среди кандидатов.", fontSize: 13)
        let layout = layout(attributed, width: 220)
        var lineY: [CGFloat] = []
        layout.1.enumerateLineFragments(forGlyphRange: layout.1.glyphRange(for: layout.2)) { _, used, _, _, _ in
            lineY.append(used.minY)
        }
        #expect(lineY.count >= 3)
        for step in zip(lineY, lineY.dropFirst()).map({ $1 - $0 }) {
            #expect(abs(step - 19.5) < 0.01)
        }
        #expect(font("Сначала", in: attributed)?.pointSize == 13)
        #expect(font("Сначала", in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .regular).fontName)
    }

    @Test func nestedBulletsWrapUnderTheirContentAtThirteenPoints() {
        let text = "1. **Проверить retrieval**\n   - Сначала измерить recall на размеченных вопросах и разобрать случаи, когда нужный документ не попал в кандидаты.\n   - Затем сравнить hybrid search на тех же вопросах."
        let attributed = HintTextFormatting.attributed(text, fontSize: 13)
        let layout = layout(attributed, width: 220)
        let string = attributed.string as NSString
        let firstItem = string.range(of: "Сначала измерить")
        let secondItem = string.range(of: "Затем сравнить")
        #expect(!attributed.string.contains("   - "))
        #expect(attributed.string.contains("•\tСначала"))
        let firstStyle = attributed.attribute(.paragraphStyle, at: firstItem.location, effectiveRange: nil) as? NSParagraphStyle
        let topicStyle = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((firstStyle?.firstLineHeadIndent ?? 0) > (topicStyle?.firstLineHeadIndent ?? 0))
        let firstGlyph = layout.1.glyphIndexForCharacter(at: firstItem.location)
        let contentX = layout.1.location(forGlyphAt: firstGlyph).x
        let itemEnd = NSMaxRange(string.paragraphRange(for: firstItem))
        let range = layout.1.glyphRange(forCharacterRange: NSRange(location: firstItem.location, length: itemEnd - firstItem.location), actualCharacterRange: nil)
        var wrappedX: [CGFloat] = []
        var lineY: [CGFloat] = []
        layout.1.enumerateLineFragments(forGlyphRange: range) { _, used, _, glyphs, _ in
            lineY.append(used.minY)
            if glyphs.location > firstGlyph { wrappedX.append(used.minX) }
        }
        print("Typography 13 pt wrapped line step: \(zip(lineY, lineY.dropFirst()).map { $1 - $0 })")
        #expect(!wrappedX.isEmpty)
        for x in wrappedX { #expect(abs(x - contentX) < 1) }
        let secondStyle = attributed.attribute(.paragraphStyle, at: secondItem.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(secondStyle?.headIndent == firstStyle?.headIndent)
    }

    @Test func listItemsStayTightAndSectionsRemainDistinct() {
        let text = "**Краткий ответ:** Сначала найти причину пропусков.\n\n**Детализированное объяснение**\n1. **Диагностика**\n   - Разобрать ошибки.\n   - Проверить разметку.\n2. **Сравнение**\n   - Повторить eval."
        let attributed = HintTextFormatting.attributed(text, fontSize: 13)
        let layout = layout(attributed, width: 430)
        let sectionGap = bounds("Детализированное", in: layout).minY - bounds("Краткий ответ:", in: layout).maxY
        let listGap = bounds("Проверить разметку.", in: layout).minY - bounds("Разобрать ошибки.", in: layout).maxY
        let headingGap = bounds("Диагностика", in: layout).minY - bounds("Детализированное", in: layout).maxY
        print("Typography 13 pt: section=\(sectionGap), list=\(listGap), heading=\(headingGap)")
        #expect(sectionGap >= 7)
        #expect(sectionGap <= 12)
        #expect(listGap >= 1)
        #expect(listGap <= 3)
        #expect(headingGap >= listGap)
        #expect(headingGap <= 5)
    }

    @Test func inlineEmphasisLeavesBodyRegularAndKeepsCodeLiteral() {
        let attributed = HintTextFormatting.attributed("**Краткий ответ:** Измерю **recall@k**, затем сравню **hybrid search** и `__name__ **literal**`.", fontSize: 13)
        for plain in ["Измерю", ", затем сравню", " и "] {
            #expect(font(plain, in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .regular).fontName)
            #expect(font(plain, in: attributed)?.pointSize == 13)
        }
        for emphasized in ["Краткий ответ:", "recall@k", "hybrid search"] {
            #expect(font(emphasized, in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .semibold).fontName)
        }
        #expect(attributed.string.contains("__name__ **literal**"))
        #expect(font("__name__", in: attributed)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func unfinishedEmphasisDoesNotExposeMarkersOrBoldPreviousBody() {
        let attributed = HintTextFormatting.attributed("Измерить **recall**, затем проверить **новую модель", fontSize: 13)
        #expect(attributed.string == "Измерить recall, затем проверить новую модель")
        #expect(font(", затем проверить", in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .regular).fontName)
        #expect(font("новую модель", in: attributed)?.fontName == NSFont.systemFont(ofSize: 13, weight: .semibold).fontName)
    }

    private func font(_ text: String, in attributed: NSAttributedString) -> NSFont? {
        let range = (attributed.string as NSString).range(of: text)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    private func layout(_ attributed: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
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
