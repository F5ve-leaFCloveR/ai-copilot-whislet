import AppKit
import SwiftUI
import Testing
import CopilotCore
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct QuestionTranslationUITests {
    @Test func hotkeyDispatchAddsTranslationWithoutChangingExistingCommands() {
        var received: [String] = []
        let registry = HotkeyRegistry { action in
            switch action {
            case .manual(nil): received.append("manual")
            case .screenshot: received.append("screenshot")
            case .hide: received.append("hide")
            case .pause: received.append("pause")
            case .previous: received.append("previous")
            case .latest: received.append("latest")
            case .translateQuestion: received.append("translate")
            default: received.append("unexpected")
            }
        }
        for index in UIHotkeys.commands.indices { registry.performHotkey(UInt32(index + 1)) }
        #expect(received == ["manual", "screenshot", "hide", "pause", "previous", "latest", "translate"])
        #expect(UISettings().hotkeyShortcut("translate") == "⌃⌥T")
    }

    @Test func translationSelectsLatestInterviewerDespiteNewerOwnSpeech() {
        let older = Utterance(source: .system, text: "Tell me about yourself.", endedAt: 1, isFinal: true)
        let question = Utterance(source: .system, text: "What was your personal contribution?", endedAt: 4, isFinal: true)
        let own = Utterance(source: .microphone, text: "Let me think.", endedAt: 5, isFinal: true)
        let selected = AppController.latestInterviewerQuestion(from: [older, question, own], latestSystem: older, after: 3)
        #expect(selected == question)
        #expect(AppController.latestInterviewerQuestion(from: [older, own], latestSystem: older, after: 3) == nil)
    }

    @Test func translationWaitsForFinalTextOfTheSelectedInterviewer() async throws {
        let partial = Utterance(source: .system, text: "Would you be", endedAt: 1, isFinal: false)
        let final = Utterance(id: partial.id, source: .system, text: "Would you be open to relocation?", endedAt: 2, isFinal: true)
        let own = Utterance(source: .microphone, text: "Yes.", endedAt: 3, isFinal: true)
        let selected = try #require(AppController.latestInterviewerQuestion(from: [partial, own], latestSystem: partial, after: 0))
        let question = try await AppController.settledManualQuestion(selected, timeout: 0.2) { [final, own] }
        #expect(question == final)
    }

    @Test func aNewTranslationRejectsLateEventsForThePreviousQuestion() {
        let first = Utterance(source: .system, text: "What is your notice period?", endedAt: 1, isFinal: true)
        let second = Utterance(source: .system, text: "What are your salary expectations?", endedAt: 2, isFinal: true)
        var translation = UIQuestionTranslation()
        let firstID = translation.begin(first)
        translation.apply(.text(firstID, "Срок уведомления"))
        let secondID = translation.begin(second)
        translation.apply(.text(firstID, "старый перевод"))
        translation.apply(.done(firstID, costRub: nil, finishReason: "stop"))
        #expect(translation.text.isEmpty)
        #expect(translation.status == .streaming)
        translation.apply(.text(secondID, "Какие у вас зарплатные ожидания?"))
        translation.apply(.done(secondID, costRub: nil, finishReason: "stop"))
        #expect(translation.question == second)
        #expect(translation.text == "Какие у вас зарплатные ожидания?")
        #expect(translation.status == .ready)
    }

    @Test func clearingTranslationInvalidatesEventsWithoutChangingTheEnglishAnswer() {
        let question = Utterance(source: .system, text: "What is your role?", endedAt: 1, isFinal: true)
        var presentation = UIPresentation()
        presentation.question = question.text
        presentation.text = "I lead development and remain hands-on."
        presentation.hintStatus = .streaming
        let answerID = UUID()
        presentation.selectedCardID = answerID
        let id = presentation.translation.begin(question)
        presentation.translation.apply(.text(id, "Какова ваша роль?"))
        presentation.translation.clear()
        presentation.translation.apply(.text(id, "Late output"))
        presentation.translation.apply(.failed(id, "Late error"))
        #expect(presentation.translation.question == nil)
        #expect(presentation.translation.text.isEmpty)
        #expect(presentation.translation.error.isEmpty)
        #expect(presentation.text == "I lead development and remain hands-on.")
        #expect(presentation.hintStatus == .streaming)
        #expect(presentation.selectedCardID == answerID)
    }

    @Test func translationCacheMatchesQuestionTextRatherThanFinalisationMetadata() {
        let partial = Utterance(source: .system, text: "What is your role", endedAt: 1, isFinal: false)
        let final = Utterance(id: partial.id, source: .system, text: partial.text, endedAt: 2, isFinal: true)
        let updated = Utterance(id: partial.id, source: .system, text: "What is your role in this project?", endedAt: 2, isFinal: true)
        var translation = UIQuestionTranslation()
        _ = translation.begin(partial)
        #expect(translation.matches(final))
        #expect(!translation.matches(updated))
        #expect(!translation.matches(Utterance(source: .system, text: partial.text, endedAt: 3, isFinal: true)))
    }

    @Test func missingSourceCanBeShownAsATranslationErrorWithoutAnAnswerError() {
        var presentation = UIPresentation()
        presentation.text = "I work on internal AI systems."
        presentation.translation.fail("Пока нет реплики собеседника для перевода")
        #expect(presentation.translation.question == nil)
        #expect(presentation.translation.status == .failed)
        #expect(presentation.translation.error == "Пока нет реплики собеседника для перевода")
        #expect(presentation.text == "I work on internal AI systems.")
        #expect(presentation.error.isEmpty)
    }

    @Test func narrowAnswerKeepsTranslationAndEnglishAnswerVisibleAndWrapped() async throws {
        _ = NSApplication.shared
        let registry = ProtectedWindowRegistry()
        registry.canShow = { _ in true }
        let model = UIModel()
        let ui = InterviewUI(model: model, registry: registry)
        defer { registry.closeAll(); registry.windows.forEach { $0.close() } }
        let original = Utterance(source: .system, text: "Could you explain your responsibilities and personal contribution to the corporate assistant?", endedAt: 1, isFinal: true)
        let russian = "Можете объяснить ваши обязанности и личный вклад в разработку корпоративного помощника?"
        let english = "I lead development and implement integrations, access controls and evaluation."
        var presentation = UIPresentation()
        presentation.phase = .listening
        presentation.question = original.text
        presentation.text = english
        presentation.selectedCardID = UUID()
        presentation.hintStatus = .ready
        let id = presentation.translation.begin(original)
        presentation.translation.apply(.text(id, russian))
        presentation.translation.apply(.done(id, costRub: nil, finishReason: "stop"))
        model.apply(presentation)
        ui.answer.setContentSize(NSSize(width: 480, height: 420))
        #expect(ui.showAnswer())
        ui.answer.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let root = try #require(ui.answer.contentView)
        let views = descendants(HintTextView.self, in: root)
        #expect(views.contains { $0.string == russian })
        #expect(views.contains { $0.string == english })
        for text in views {
            let frame = text.convert(text.bounds, to: root)
            #expect(frame.minX >= 12)
            #expect(frame.maxX <= root.bounds.width - 12 + 1)
            if let container = text.textContainer, let manager = text.layoutManager {
                manager.ensureLayout(for: container)
                #expect(manager.usedRect(for: container).maxX <= text.bounds.width + 1)
            }
        }
        try ui.writePreview(to: URL(fileURLWithPath: "/tmp/whislet-question-translation-narrow.png"))
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
}
