import Foundation
import Testing
import CopilotCore
@testable import InterviewCopilot

@Suite struct ManualAnswerSelectionTests {
    @Test @MainActor func pendingAudioUsesFinalText() async throws {
        let partial = Utterance(source: .microphone, text: "What is your", endedAt: 1, isFinal: false)
        let final = Utterance(id: partial.id, source: .microphone, text: "What is your team size?", endedAt: 2, isFinal: true)
        var snapshots = 0
        let question = try await AppController.settledManualQuestion(partial, timeout: 0.2) {
            snapshots += 1
            return [snapshots == 1 ? partial : final]
        }
        #expect(question == final)
    }

    @Test @MainActor func pendingAudioUsesLatestPartialAtDeadline() async throws {
        let partial = Utterance(source: .microphone, text: "What is your", endedAt: 1, isFinal: false)
        let updated = Utterance(id: partial.id, source: .microphone, text: "What is your team size", endedAt: 2, isFinal: false)
        let question = try await AppController.settledManualQuestion(partial, timeout: 0.05) { [updated] }
        #expect(question == updated)
        #expect(!question.isFinal)
    }

    @Test @MainActor func pendingAudioDoesNotSwitchToAnotherUtterance() async throws {
        let partial = Utterance(source: .microphone, text: "What is your team size", endedAt: 1, isFinal: false)
        let other = Utterance(source: .system, text: "Another question?", endedAt: 2, isFinal: true)
        let question = try await AppController.settledManualQuestion(partial, timeout: 0.05) { [other] }
        #expect(question == partial)
    }

    @Test @MainActor func pendingAudioCanBeCancelled() async throws {
        let partial = Utterance(source: .microphone, text: "What is your", endedAt: 1, isFinal: false)
        let task = Task { try await AppController.settledManualQuestion(partial) { [partial] } }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled audio selection returned a question")
        } catch is CancellationError { }
    }

    @Test func expandedPartialRequiresGenerationForUpdatedText() {
        let utteranceID = UUID()
        let original = Utterance(id: utteranceID, source: .system, text: "Как устроена RAG-архитектура?", endedAt: 1, isFinal: false)
        var state = SessionReducer()
        _ = state.begin(question: original)
        let updated = Utterance(id: utteranceID, source: .system, text: "Как устроена RAG-архитектура? Теперь какие критерии выбора LLM?", endedAt: 2, isFinal: false)
        #expect(!AppController.shouldReuseActiveAnswer(updated, in: state, screenshot: false))
        #expect(state.latestCard?.question.text == "Как устроена RAG-архитектура?")
    }

    @Test func sameTextReusesActiveAnswerButNewUtteranceAndScreenshotDoNot() {
        let original = Utterance(source: .system, text: "Как выбрать модель для RAG?", endedAt: 1, isFinal: false)
        var state = SessionReducer()
        _ = state.begin(question: original)
        let finalized = Utterance(id: original.id, source: .system, text: original.text, endedAt: 2, isFinal: true)
        #expect(AppController.shouldReuseActiveAnswer(finalized, in: state, screenshot: false))
        let separate = Utterance(source: .system, text: original.text, endedAt: 3, isFinal: true)
        #expect(!AppController.shouldReuseActiveAnswer(separate, in: state, screenshot: false))
        #expect(!AppController.shouldReuseActiveAnswer(finalized, in: state, screenshot: true))
    }

    @Test func completedAnswerCanBeGeneratedAgain() {
        let question = Utterance(source: .system, text: "Какие критерии выбора LLM?", endedAt: 1, isFinal: true)
        var state = SessionReducer()
        #expect(!AppController.shouldReuseActiveAnswer(question, in: state, screenshot: false))
        let requestID = state.begin(question: question)
        state.apply(.done(requestID, costRub: nil, finishReason: "stop"))
        #expect(!AppController.shouldReuseActiveAnswer(question, in: state, screenshot: false))
    }
}
