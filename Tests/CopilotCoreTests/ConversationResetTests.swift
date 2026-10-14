import Foundation
import Testing
@testable import CopilotCore

@Suite struct ConversationResetTests {
    @Test func profileSwitchClearsOldAnswersAndRejectsLateEvents() {
        var state = SessionReducer()
        let question = Utterance(source: .microphone, text: "Мой вопрос", endedAt: 1, isFinal: true)
        let id = state.begin(question: question)
        state.apply(.text(id, "Ответ другого профиля"))
        state.apply(.suggestions(id, ["Старое уточнение"]))
        state.appendTranscript(question)
        state.hide()
        state.resetConversation()
        state.apply(.text(id, "Поздний ответ"))
        #expect(state.cards.isEmpty && state.transcript.isEmpty)
        #expect(state.activeRequestID == nil && state.selectedCardID == nil)
        #expect(state.isRunning && state.isHidden && !state.isPaused)
    }

    @Test func profileSwitchPreservesPausedCaptureState() {
        var state = SessionReducer()
        state.pause(); state.resetConversation()
        #expect(state.isRunning && state.isPaused)
        state.stop(); state.resetConversation()
        #expect(!state.isRunning && !state.isPaused)
    }
}
