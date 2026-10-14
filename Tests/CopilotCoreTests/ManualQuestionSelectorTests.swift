import Foundation
import Testing
@testable import CopilotCore

@Suite struct ManualQuestionSelectorTests {
    @Test func ownSpokenQuestionCanBeSelectedWithoutSystemAudio() throws {
        let own = speech(.microphone, "Как устроен event loop?", at: 10)
        let selected = try #require(ManualQuestionSelector.select(from: [own]))
        #expect(selected.question == own)
        #expect(selected.context == [own])
    }

    @Test func ownClarificationBecomesCurrentQuestionAndRetainsRemoteQuestion() throws {
        let remote = speech(.system, "Как бы ты ускорил retrieval?", at: 10)
        let own = speech(.microphone, "У нас миллион документов и есть reranker", at: 12)
        let selected = try #require(ManualQuestionSelector.select(from: [remote, own]))
        #expect(selected.question == own)
        #expect(selected.context == [remote, own])
    }

    @Test func unfinishedRemoteSpeechRemainsInOwnQuestionContext() throws {
        let remote = speech(.system, "Сравните Redis и", at: 10, final: false)
        let own = speech(.microphone, "Нужен cache без persistence", at: 11, final: false)
        let selected = try #require(ManualQuestionSelector.select(from: [own, remote]))
        #expect(selected.question == own)
        #expect(selected.context == [remote, own])
        #expect(!selected.context[0].isFinal)
    }

    @Test func sameIDGrowthReplacesOldTextAndDoesNotDuplicateContext() throws {
        let id = UUID()
        let partial = speech(.microphone, "Покажи", at: 10, final: false, id: id)
        let expanded = speech(.microphone, "Покажи пример async endpoint", at: 11, final: false, id: id)
        let final = speech(.microphone, "Покажи пример async endpoint с timeout", at: 12, id: id)
        let selected = try #require(ManualQuestionSelector.select(from: [partial, expanded, final]))
        #expect(selected.question == final)
        #expect(selected.context == [final])
    }

    @Test func equalTimeFinalSurvivesDelayedPartialWithSameID() throws {
        let id = UUID()
        let final = speech(.system, "Объясни precision и recall", at: 10, id: id)
        let latePartial = speech(.system, "Объясни precision", at: 10, final: false, id: id)
        let selected = try #require(ManualQuestionSelector.select(from: [final, latePartial]))
        #expect(selected.question == final)
        #expect(selected.context == [final])
    }

    @Test func newerEndingWinsOverDelayedOlderFinalWithSameID() throws {
        let id = UUID()
        let fresh = speech(.system, "Как выбрать LLM для RAG?", at: 12, final: false, id: id)
        let oldFinal = speech(.system, "Как выбрать LLM?", at: 10, id: id)
        let selected = try #require(ManualQuestionSelector.select(from: [fresh, oldFinal]))
        #expect(selected.question == fresh)
        #expect(selected.context == [fresh])
    }

    @Test func latestSameTimeRecognitionCorrectionCanShortenText() throws {
        let id = UUID()
        let before = speech(.microphone, "Как устроена устроена очередь?", at: 10, final: false, id: id)
        let corrected = speech(.microphone, "Как устроена очередь?", at: 10, final: false, id: id)
        let selected = try #require(ManualQuestionSelector.select(from: [before, corrected]))
        #expect(selected.question == corrected)
        #expect(selected.context == [corrected])
    }

    @Test func delayedOldMicrophoneDoesNotReplaceNewRemoteQuestion() throws {
        let remote = speech(.system, "Какие критерии выбора LLM?", at: 20)
        let oldOwn = speech(.microphone, "Давай пример по RAG", at: 10)
        let selected = try #require(ManualQuestionSelector.select(from: [remote, oldOwn]))
        #expect(selected.question == remote)
        #expect(selected.context == [oldOwn, remote])
    }

    @Test func whitespaceDoesNotHideExistingQuestionAndEmptyInputReturnsNothing() throws {
        let own = speech(.microphone, "Как проверить качество?", at: 10)
        let empty = speech(.system, " \n\t", at: 30)
        let selected = try #require(ManualQuestionSelector.select(from: [own, empty]))
        #expect(selected.question == own)
        #expect(selected.context == [own])
        #expect(ManualQuestionSelector.select(from: []) == nil)
        #expect(ManualQuestionSelector.select(from: [empty]) == nil)
    }

    @Test func equalTimeSourcesPreferOwnSpeechRegardlessOfArrivalOrder() throws {
        let remote = speech(.system, "Зачем нужен reranker?", at: 10)
        let own = speech(.microphone, "Покажи пример", at: 10, final: false)
        let first = try #require(ManualQuestionSelector.select(from: [remote, own]))
        let reversed = try #require(ManualQuestionSelector.select(from: [own, remote]))
        #expect(first.question == own)
        #expect(reversed.question == own)
        #expect(first.context == reversed.context)
    }

    @Test func equalTimeSameSourceOrderingIsStableAcrossSnapshots() throws {
        let low = speech(.system, "Первый вопрос", at: 10, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = speech(.system, "Второй вопрос", at: 10, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let first = try #require(ManualQuestionSelector.select(from: [high, low]))
        let reversed = try #require(ManualQuestionSelector.select(from: [low, high]))
        #expect(first.question == high)
        #expect(first.context == [low, high])
        #expect(first.context == reversed.context)
    }

    private func speech(_ source: AudioSource, _ text: String, at time: Double, final: Bool = true, id: UUID = UUID()) -> Utterance {
        Utterance(id: id, source: source, text: text, endedAt: time, isFinal: final)
    }
}
