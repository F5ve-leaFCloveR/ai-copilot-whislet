import AppKit
import SwiftUI
import Testing
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct AnswerSurfaceTests {
    private func ui() -> InterviewUI {
        _ = NSApplication.shared
        let registry = ProtectedWindowRegistry()
        registry.canShow = { _ in true }
        return InterviewUI(model: UIModel(), registry: registry)
    }

    @Test func answerMovePreservesGroupGeometry() {
        let ui = ui()
        defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
        #expect(ui.showAnswer())
        let offset = ui.answerOffset
        let toolbar = ui.toolbar.frame
        ui.answer.setFrameOrigin(NSPoint(x: ui.answer.frame.minX + 48, y: ui.answer.frame.minY - 20))
        ui.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: ui.answer))
        #expect(abs(ui.answerOffset.x - offset.x) < 1)
        #expect(abs(ui.answerOffset.y - offset.y) < 1)
        #expect(abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1)
        #expect(abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1)
        #expect(!ui.answer.isMovableByWindowBackground)
        #expect(ui.toolbar.frame != toolbar || ui.answerOffset == offset)
    }

    @Test func answerResizeKeepsAttachedTopAndCenter() {
        let ui = ui()
        defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
        #expect(ui.showAnswer())
        ui.answer.setFrame(NSRect(x: ui.answer.frame.minX + 25, y: ui.answer.frame.minY - 50, width: 760, height: 510), display: false)
        ui.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: ui.answer))
        #expect(abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1)
        #expect(abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1)
    }

    @Test func textContainerTracksRealWidthAfterResize() async {
        let longText = String(repeating: "Проверяем длинную строку русского текста с подробным техническим объяснением без сокращений. ", count: 10)
        let host = NSHostingView(rootView: NativeHintText(text: longText, fontSize: 17, cardID: nil) { _, _ in })
        host.frame = NSRect(x: 0, y: 0, width: 630, height: 400)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.frame.size.width = 390
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        guard let text = descendant(HintTextView.self, in: host), let container = text.textContainer, let manager = text.layoutManager else {
            Issue.record("NativeHintText не создал NSTextView")
            return
        }
        manager.ensureLayout(for: container)
        #expect(container.containerSize.width <= text.bounds.width + 1)
        #expect(manager.usedRect(for: container).maxX <= text.bounds.width + 1)
        #expect(manager.glyphRange(for: container).length == manager.numberOfGlyphs)
    }

    @Test func narrowAnswerKeepsLongTextInsideItsViewport() async {
        let ui = ui()
        defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
        let body = String(repeating: "Длинное объяснение должно занимать ширину карточки и переноситься на следующую строку. ", count: 20)
        var presentation = UIPresentation()
        presentation.phase = .listening
        presentation.hintStatus = .ready
        presentation.selectedCardID = UUID()
        presentation.question = "Как устроена асинхронность?"
        presentation.text = body + "\n" + String(repeating: "LongIdentifierWithoutWhitespace", count: 30)
        ui.model.apply(presentation)
        ui.answer.setContentSize(NSSize(width: 480, height: 360))
        #expect(ui.showAnswer())
        ui.answer.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        guard let root = ui.answer.contentView, let text = descendant(HintTextView.self, in: root), let container = text.textContainer, let manager = text.layoutManager else {
            Issue.record("AnswerSurface не создал NSTextView")
            return
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let frame = text.convert(text.bounds, to: root)
        print("Answer layout: root=\(root.bounds), text=\(text.bounds), container=\(container.containerSize), used=\(used), frame=\(frame)")
        #expect(abs(ui.answer.frame.width - 480) < 1)
        #expect(root.bounds.width <= 480)
        #expect(container.containerSize.width.isFinite)
        #expect(frame.minX >= 12)
        #expect(frame.maxX <= root.bounds.width - 12 + 1)
        #expect(used.maxX <= text.bounds.width + 1)
        #expect(used.maxY <= text.bounds.height + 2)
        #expect(manager.glyphRange(for: container).length == manager.numberOfGlyphs)
    }

    @Test func answerPreservesParagraphsAndFormatsInlineEmphasis() async {
        let host = NSHostingView(rootView: NativeHintText(text: "**Короткий ответ**\n\nОбычный абзац с `async` и переносом.", fontSize: 17, cardID: nil) { _, _ in })
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 400)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        guard let text = descendant(HintTextView.self, in: host), let storage = text.textStorage else {
            Issue.record("NativeHintText не создал NSTextView")
            return
        }
        #expect(text.string == "Короткий ответ\n\nОбычный абзац с async и переносом.")
        let firstFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(firstFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }

    @Test func inlineCodePreservesDunderAndMarkdownSymbols() async {
        let input = "`__init__` вызывает `__enter__`; `**literal**` и `*args` остаются кодом.\n**Вызвать `__exit__` после блока**"
        let host = NSHostingView(rootView: NativeHintText(text: input, fontSize: 17, cardID: nil) { _, _ in })
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 400)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        guard let text = descendant(HintTextView.self, in: host), let storage = text.textStorage else {
            Issue.record("NativeHintText не создал NSTextView")
            return
        }
        #expect(text.string == "__init__ вызывает __enter__; **literal** и *args остаются кодом.\nВызвать __exit__ после блока")
        for identifier in ["__init__", "__enter__", "**literal**", "*args", "__exit__"] {
            let range = (text.string as NSString).range(of: identifier)
            #expect(range.location != NSNotFound)
            guard range.location != NSNotFound else { continue }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        }
    }

    @Test func outerBoldIgnoresDelimitersInsideInlineCode() async {
        let host = NSHostingView(rootView: NativeHintText(text: "**Используйте `**literal**` как строку**", fontSize: 17, cardID: nil) { _, _ in })
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 400)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        guard let text = descendant(HintTextView.self, in: host), let storage = text.textStorage else {
            Issue.record("NativeHintText не создал NSTextView")
            return
        }
        #expect(text.string == "Используйте **literal** как строку")
        let bodyFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(bodyFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let codeRange = (text.string as NSString).range(of: "**literal**")
        #expect(codeRange.location != NSNotFound)
        if codeRange.location != NSNotFound {
            let codeFont = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
            #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        }
    }

    @Test func headerDragMovesRigidGroupWithoutCoordinateJumps() {
        for answerHeader in [true, false] {
            let ui = ui()
            defer { ui.registry.closeAll(); ui.registry.windows.forEach { $0.close() } }
            #expect(ui.showAnswer())
            let source: NSWindow = answerHeader ? ui.answer : ui.toolbar
            guard let root = source.contentView, let drag = descendant(NativeDragView.self, in: root) else {
                Issue.record("Заголовок не содержит NativeDragView")
                continue
            }
            let origin = ui.toolbar.frame.origin
            let pointer = NSPoint(x: source.frame.midX, y: source.frame.maxY - 20)
            let down = mouse(.leftMouseDown, at: pointer, in: source)
            #expect(drag.acceptsFirstMouse(for: down))
            #expect(!drag.mouseDownCanMoveWindow)
            drag.mouseDown(with: down)
            ui.toggleQuickSettings()
            let first = NSPoint(x: pointer.x + 30, y: pointer.y - 15)
            drag.mouseDragged(with: mouse(.leftMouseDragged, at: first, in: source))
            #expect(abs(ui.toolbar.frame.minX - origin.x - 30) < 1)
            #expect(abs(ui.toolbar.frame.minY - origin.y + 15) < 1)
            #expect(!ui.quickSettings.isVisible)
            #expect(abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1)
            #expect(abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1)
            let afterFirst = ui.toolbar.frame
            drag.mouseDragged(with: mouse(.leftMouseDragged, at: first, in: source))
            #expect(ui.toolbar.frame == afterFirst)
            let second = NSPoint(x: pointer.x + 55, y: pointer.y - 35)
            drag.mouseDragged(with: mouse(.leftMouseDragged, at: second, in: source))
            #expect(abs(ui.toolbar.frame.minX - origin.x - 55) < 1)
            #expect(abs(ui.toolbar.frame.minY - origin.y + 35) < 1)
            #expect(abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1)
            #expect(abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1)
            drag.mouseUp(with: mouse(.leftMouseUp, at: second, in: source))
            let released = ui.toolbar.frame
            drag.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: pointer.x + 75, y: pointer.y - 45), in: source))
            #expect(ui.toolbar.frame == released)
        }
    }

    private func mouse(_ type: NSEvent.EventType, at screenPoint: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = descendant(type, in: child) { return result }
        }
        return nil
    }
}
