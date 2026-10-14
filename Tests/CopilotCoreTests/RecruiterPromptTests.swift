import Foundation
import Testing
@testable import CopilotCore

@Suite struct RecruiterPromptTests {
    @Test func recruiterModeStreamsSpokenEnglishEvenWithDefaultPreset() throws {
        let question = Utterance(source: .system, text: "What are your salary expectations?", endedAt: 1, isFinal: true)
        let preset = ModelPreset(model: "gemini-3.8-flash", reasoningEffort: "minimal", maxTokens: 1024)
        let request = HintRequest(question: question, profile: "Fictional candidate: $60,000 gross per year", preset: preset, mode: .recruiterInterview)
        #expect(!request.usesStructuredOutput)
        #expect(request.preset == preset)
        let payload = try #require(JSONSerialization.jsonObject(with: PromptBuilder().build(request)) as? [String: Any])
        #expect(payload["response_format"] == nil)
        #expect(payload["max_tokens"] as? Int == 1024)
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let rules = try #require(messages.first?["content"] as? String)
        #expect(rules.contains("English only"))
        #expect(rules.contains("chosen wording"))
        #expect(rules.contains("gross"))
        #expect(rules.contains("currency"))
        #expect(!rules.contains("Этот кейс не описан в профиле"))
        #expect(!rules.contains("В определении LoRA"))
    }

    @Test func recruiterFallbackOffersAnAnswerWithoutInventedPastFacts() throws {
        let question = Utterance(source: .microphone, text: "What would I like to improve?", endedAt: 2, isFinal: true)
        let previous = HintCard(id: UUID(), question: question, text: "I saved millions at a previous employer.", status: .ready)
        let request = HintRequest(question: question, profile: "Fictional candidate: English C1; practising presentations.", previousHint: previous, mode: .recruiterInterview)
        let payload = try #require(JSONSerialization.jsonObject(with: PromptBuilder().build(request)) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let rules = try #require(messages.first?["content"] as? String)
        #expect(rules.contains("not in the bank"))
        #expect(rules.contains("future approach"))
        #expect(rules.contains("not proof"))
        #expect(rules.contains("notice period"))
        #expect(rules.contains("two weeks"))
        #expect(!request.usesStructuredOutput)
    }

    @Test func existingModesKeepPresetOutputPolicy() {
        let question = Utterance(source: .system, text: "Вопрос?", endedAt: 1, isFinal: true)
        for mode in [ConversationMode.interview, .work] {
            #expect(HintRequest(question: question, mode: mode).usesStructuredOutput)
            #expect(!HintRequest(question: question, preset: ModelPreset(structuredShort: false), mode: mode).usesStructuredOutput)
        }
    }
}
