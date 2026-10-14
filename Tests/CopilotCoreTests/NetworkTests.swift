import Foundation
import Testing
@testable import CopilotCore

@Suite struct NetworkTests {
    @Test func codeBudgetPreservesCompleteImplementations() throws {
        let source = (0..<60).map { "value\($0) = \"one two three four\"" }.joined(separator: "\n")
        let code = "```python\n" + source + "\n```"
        let data = try JSONSerialization.data(withJSONObject: ["points": [code, "Полная реализация."], "followups": [] as [String]])
        var decoder = IncrementalHintDecoder(requireFollowups: true)
        _ = try decoder.feed(String(decoding: data, as: UTF8.self))
        #expect(try decoder.finish() == [code, "Полная реализация."])
    }

    @Test func emptyAndUnclosedCodeCannotFinish() throws {
        for code in ["```python\n```", "```python\nanswer = 42"] {
            let data = try JSONSerialization.data(withJSONObject: ["points": [code], "followups": [] as [String]])
            var decoder = IncrementalHintDecoder(requireFollowups: true)
            _ = try decoder.feed(String(decoding: data, as: UTF8.self))
            #expect(throws: (any Error).self) { try decoder.finish() }
        }
    }

    @Test func productionDecoderRequiresFollowupsButLegacyDecoderAcceptsPointsOnly() throws {
        let legacy = #"{"points":["Ответ"]}"#
        var strict = IncrementalHintDecoder(requireFollowups: true)
        _ = try strict.feed(legacy)
        #expect(throws: StreamDecodeError.incomplete) { try strict.finish() }
        var compatible = IncrementalHintDecoder()
        _ = try compatible.feed(legacy)
        #expect(try compatible.finish() == ["Ответ"])
        var complete = IncrementalHintDecoder(requireFollowups: true)
        _ = try complete.feed(#"{"points":["Подтверждённый факт"],"followups":[]}"#)
        #expect(try complete.finish() == ["Подтверждённый факт"])
        #expect(complete.followups.isEmpty)
    }
    @Test func structuredAnswerPreservesMarkdownAndAcceptsCompletedFollowups() throws {
        var decoder = IncrementalHintDecoder()
        let text = #"{"points":["Прямой ответ","1. **Проверить кандидатов**\n   - Измерить recall@10."],"followups":["Как сравнить hybrid search?","Как подобрать размер chunk?"]}"#
        var streamed: [String] = []
        for character in text { streamed = try decoder.feed(String(character)) }
        #expect(streamed == ["Прямой ответ", "1. **Проверить кандидатов**\n   - Измерить recall@10."])
        #expect(try decoder.finish() == streamed)
        #expect(decoder.followups == ["Как сравнить hybrid search?", "Как подобрать размер chunk?"])
    }
    @Test func followupsMayPrecedePointsAndMayBeEmpty() throws {
        for text in [
            #"{"followups":["Объясни метрику"],"points":["Технический ответ"]}"#,
            #"{"points":["Подтверждённый факт"],"followups":[]}"#
        ] {
            var decoder = IncrementalHintDecoder()
            _ = try decoder.feed(text)
            #expect(try decoder.finish().count == 1)
        }
    }
    @Test func followupsStaySeparateAndAppearOnlyAfterClosingQuote() throws {
        var decoder = IncrementalHintDecoder()
        #expect(try decoder.feed(#"{"points":["Ответ"],"followups":["Как использовать \"API\"?"#) == ["Ответ"])
        #expect(decoder.followups.isEmpty)
        #expect(try decoder.feed(#"","Покажи \uD83D"#) == ["Ответ"])
        #expect(decoder.followups == ["Как использовать \"API\"?"])
        #expect(try decoder.feed(#"\uDE00 пример"]}"#) == ["Ответ"])
        #expect(decoder.followups == ["Как использовать \"API\"?", "Покажи 😀 пример"])
        #expect(try decoder.finish() == ["Ответ"])
    }
    @Test func validFollowupsDoNotCompleteAnUnclosedObject() throws {
        var decoder = IncrementalHintDecoder()
        _ = try decoder.feed(#"{"points":["Ответ"],"followups":["Уточнить"]"#)
        #expect(decoder.followups == ["Уточнить"])
        #expect(throws: StreamDecodeError.incomplete) { try decoder.finish() }
    }
    @Test func missingPointsAndInvalidFollowupShapeCannotFinish() {
        for text in [
            #"{"followups":[]}"#,
            #"{"points":["Ответ"],"followups":["1","2","3","4"]}"#,
            #"{"points":["Ответ"],"followups":[null]}"#,
            #"{"points":["Ответ"],"followups":[""]}"#,
            #"{"points":["Ответ"],"followups":["раз два три четыре пять шесть семь восемь девять десять одиннадцать двенадцать тринадцать"]}"#,
            #"{"points":["Ответ"],"followups":[],"followups":[]}"#,
            #"{"points":["Ответ"],"points":["Другой"]}"#,
            #"{"points":["Ответ"],"unknown":[]}"#,
            #"{"points":["Ответ"],"followups":[],}"#,
            #"{"points":["Ответ"],"followups":["Уточнить",]}"#
        ] {
            #expect(throws: (any Error).self) {
                var decoder = IncrementalHintDecoder()
                _ = try decoder.feed(text)
                _ = try decoder.finish()
            }
        }
    }
    @Test func oversizedFinalHintAndKnownAssistantMarkerAreRejected() throws {
        var decoder = IncrementalHintDecoder()
        let text = String(repeating: "word ", count: 241)
        let data = try JSONSerialization.data(withJSONObject: ["points": [text, "B", "C"]])
        _ = try decoder.feed(String(decoding: data, as: UTF8.self))
        #expect(throws: StreamDecodeError.excessiveWords) { try decoder.finish() }
        var guardrail = ContentGuard()
        _ = guardrail.accept("$_['assi")
        #expect(guardrail.acceptedText.isEmpty)
        _ = guardrail.accept("stant}")
        #expect(guardrail.isCorrupt)
    }
    @Test func completeStructuredAnswerMayUseTheFullBodyBudget() throws {
        var decoder = IncrementalHintDecoder()
        let text = String(repeating: "слово ", count: 240)
        let data = try JSONSerialization.data(withJSONObject: ["points": [text], "followups": ["Поясни пример"]])
        _ = try decoder.feed(String(decoding: data, as: UTF8.self))
        #expect(try decoder.finish() == [text])
    }
    @Test func explanationCanExceedOldBulletLimitWithoutTruncation() throws {
        var decoder = IncrementalHintDecoder()
        let explanation = String(repeating: "слово ", count: 100)
        let data = try JSONSerialization.data(withJSONObject: ["points": ["Прямой ответ", explanation, "Пример"]])
        _ = try decoder.feed(String(decoding: data, as: UTF8.self))
        let parts = try decoder.finish()
        #expect(parts == ["Прямой ответ", explanation, "Пример"])
    }
    @Test func testSSEPreservesUTF8AcrossBytesAndIgnoresComments() throws {
        var decoder = SSEDecoder()
        let bytes = Array(": ping\r\ndata: Привет\r\n\r\ndata: [DONE]\n\n".utf8)
        var events: [SSEEvent] = []
        for byte in bytes { events += try decoder.feed(Data([byte])) }
        #expect(events == [.data("Привет"), .done])
    }
    @Test func testPartialJSONAppearsBeforeClosingObjectWithoutEscapeFragments() throws {
        var decoder = IncrementalHintDecoder()
        let result1 = try decoder.feed("{\"points\":[\"Первый \\u04").first == "Первый "
        #expect(result1)
        let points = try decoder.feed("30 \\\"код\\\" {x}\",\"Второй\",\"Третий\"]}")
        #expect(points == ["Первый а \"код\" {x}", "Второй", "Третий"])
        #expect(try decoder.finish() == points)
    }
    @Test func testEOFUnexpectedKeyAndFourPointsCannotFinish() throws {
        var partial = IncrementalHintDecoder()
        _ = try partial.feed("{\"points\":[\"Первый")
        #expect(throws: (any Error).self) { try partial.finish() }
        var wrongKey = IncrementalHintDecoder()
        #expect(throws: (any Error).self) { try wrongKey.feed("{\"answer\":[\"Один\"]}") }
        var extra = IncrementalHintDecoder()
        #expect(throws: (any Error).self) { try extra.feed("{\"points\":[\"1\",\"2\",\"3\",\"4\"]}") }
    }
    @Test func testSurrogatePairAppearsOnlyWhenComplete() throws {
        var decoder = IncrementalHintDecoder()
        let result4 = try decoder.feed("{\"points\":[\"A\\uD83D").first == "A"
        #expect(result4)
        let result5 = try decoder.feed("\\uDE00\",\"B\",\"C\"]}").first == "A😀"
        #expect(result5)
        #expect(try decoder.finish().count == 3)
    }
    @Test func testSplitModelMarkerIsWithheldButOrdinaryHTMLAllowed() {
        var guardrail = ContentGuard()
        let result6 = !guardrail.accept("</fi")
        #expect(result6)
        #expect(guardrail.acceptedText.isEmpty)
        let result7 = !guardrail.accept("nal>")
        #expect(result7)
        #expect(guardrail.isCorrupt)
        var html = ContentGuard()
        let result8 = html.accept("<div>код</div>")
        #expect(result8)
        #expect(html.acceptedText == "<div>код</div>")
    }
    @Test func testPromptRetainsQuestionAndBoundsProfileAndRecentConversation() throws {
        let newest = Utterance(source: .system, text: String(repeating: "x", count: 8_000), endedAt: 2, isFinal: true)
        let oldest = Utterance(source: .system, text: String(repeating: "z", count: 8_000), endedAt: 1, isFinal: true)
        let request = HintRequest(question: remoteQuestion("Последний вопрос целиком?"), context: [oldest, newest], profile: "Python")
        let object = try #require(JSONSerialization.jsonObject(with: PromptBuilder().build(request)) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? String)
        #expect(content.contains("Последний вопрос целиком?"))
        #expect(content.contains(String(repeating: "x", count: 8_000)))
        #expect(!content.contains(String(repeating: "z", count: 100)))
        #expect(throws: (any Error).self) { try PromptBuilder().build(HintRequest(question: remoteQuestion("Вопрос?"), profile: String(repeating: "я", count: 6_001))) }
    }
    @Test func providerReceivesAnswerRulesAndProfileInOneSystemMessage() throws {
        let profile = "Я редактировал Kubernetes manifests; результат не указан."
        let messages = try payloadMessages(HintRequest(question: remoteQuestion("Какой получил результат?"), profile: profile))
        let systems = messages.filter { $0["role"] as? String == "system" }
        #expect(systems.count == 1)
        let system = try #require(systems.first?["content"] as? String)
        #expect(system.contains("points"))
        #expect(system.contains("followups"))
        #expect(system.contains("Этот кейс не описан в профиле — уточни реальный опыт"))
        #expect(system.contains(profile))
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.last?["content"] as? String == "Собеседник: Какой получил результат?")
    }
    @Test func clarificationIncludesSelectedQuestionAndAnswerAsHistory() throws {
        let previousQuestion = remoteQuestion("Зачем нужен reranker?")
        let previous = HintCard(id: UUID(), question: previousQuestion, text: "Он пересортировывает найденные документы.", status: .ready)
        let audio = remoteQuestion("Последняя реплика собеседника")
        let request = HintRequest(question: remoteQuestion("Покажи пример"), context: [previousQuestion, audio], profile: "Python", previousHint: previous)
        let messages = try payloadMessages(request)
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        try #require(messages.count == 4)
        #expect(messages[1]["content"] as? String == "Собеседник: " + previousQuestion.text)
        #expect(messages[2]["content"] as? String == previous.text)
        let current = try #require(messages.last?["content"] as? String)
        #expect(current.hasSuffix("Собеседник: Последняя реплика собеседника\nСобеседник: Покажи пример"))
        #expect(current.contains("<selected_question>" + previousQuestion.text + "</selected_question>"))
        #expect(current.contains(previous.text))
        let instruction = try #require(messages.first?["content"] as? String)
        #expect(instruction.contains("Предыдущий ответ — справочный контекст"))
        #expect(instruction.contains("не источник фактов о кандидате"))
    }
    @Test func clarificationCapturesSelectedHistoryBeforeBeginningNewCard() throws {
        var state = SessionReducer()
        let olderID = state.begin(question: remoteQuestion("Первый вопрос?"))
        state.apply(.text(olderID, "Ответ на первый вопрос")); state.apply(.done(olderID, costRub: 0, finishReason: "stop"))
        let latestID = state.begin(question: remoteQuestion("Второй вопрос?"))
        state.apply(.text(latestID, "Несвязанный новый ответ")); state.apply(.done(latestID, costRub: 0, finishReason: "stop"))
        state.selectHistory(olderID)
        let previous = HintRequest.clarificationContext(for: "Объясни подробнее", selectedCard: state.selectedCard)
        let question = remoteQuestion("Объясни подробнее")
        let nextID = state.begin(question: question)
        let request = HintRequest(id: nextID, question: question, previousHint: previous)
        let messages = try payloadMessages(request)
        #expect(state.selectedCardID == nextID)
        #expect(request.previousHint?.id == olderID)
        #expect(messages.contains { $0["content"] as? String == "Ответ на первый вопрос" })
        #expect(!messages.contains { ($0["content"] as? String)?.contains("Несвязанный новый ответ") == true })
        #expect(HintRequest.clarificationContext(for: nil, selectedCard: previous) == nil)
        #expect(HintRequest.clarificationContext(for: " \n", selectedCard: previous) == nil)
        #expect(HintRequest.clarificationContext(for: "Объясни", screenshot: true, selectedCard: previous) == nil)
    }
    @Test func clarificationBoundsUTF8HistoryAndRetainsWholeCurrentQuestion() throws {
        let question = remoteQuestion(String(repeating: "я", count: 3_000) + " — текущий вопрос целиком?")
        let oldQuestion = remoteQuestion(String(repeating: "👩🏽‍💻", count: 500))
        let oldAnswer = String(repeating: "е\u{301}🧑‍🔬", count: 500)
        let previous = HintCard(id: UUID(), question: oldQuestion, text: oldAnswer, status: .ready)
        let excluded = remoteQuestion(String(repeating: "OLD", count: 4_000))
        let audio = remoteQuestion("Новая реплика " + String(repeating: "A", count: 1_800))
        let request = HintRequest(question: question, context: [excluded, oldQuestion, audio], previousHint: previous)
        let messages = try payloadMessages(request)
        let contextual = try messages.dropFirst().map { try #require($0["content"] as? String) }
        try #require(contextual.count == 3)
        #expect(contextual.reduce(0) { $0 + $1.utf8.count } <= 12_000)
        #expect(contextual[0].utf8.count <= 2_000)
        #expect(contextual[1].utf8.count <= 4_000)
        #expect(("Собеседник: " + oldQuestion.text).hasPrefix(contextual[0]))
        #expect(oldAnswer.hasPrefix(contextual[1]))
        #expect(contextual[0].dropFirst("Собеседник: ".count).allSatisfy { $0 == "👩🏽‍💻" })
        #expect(contextual[1].allSatisfy { $0 == "е\u{301}" || $0 == "🧑‍🔬" })
        #expect(contextual[2].hasSuffix("Собеседник: " + question.text))
        #expect(!contextual[2].contains("OLD"))
        #expect(!contextual[2].contains("👩🏽‍💻"))
        let shorter = try payloadMessages(HintRequest(question: remoteQuestion("Покажи пример"), context: [excluded, oldQuestion, audio], previousHint: previous))
        let current = try #require(shorter.last?["content"] as? String)
        #expect(current.contains(audio.text))
        #expect(current.hasSuffix("Собеседник: Покажи пример"))
        #expect(!current.contains("OLD"))
    }
    @Test func emptyPreviousAnswerAndNearLimitQuestionDoNotConsumeHistoryBudget() throws {
        let empty = HintCard(id: UUID(), question: remoteQuestion("Старый вопрос"), text: " \n", status: .waiting)
        let audio = remoteQuestion("Реплика")
        let question = remoteQuestion("Новый вопрос")
        let withEmpty = try payloadMessages(HintRequest(question: question, context: [audio], previousHint: empty))
        let without = try payloadMessages(HintRequest(question: question, context: [audio]))
        #expect(withEmpty.map { $0["role"] as? String } == without.map { $0["role"] as? String })
        #expect(withEmpty.last?["content"] as? String == without.last?["content"] as? String)
        let nearLimit = remoteQuestion(String(repeating: "x", count: 11_977))
        let previous = HintCard(id: UUID(), question: remoteQuestion("👩🏽‍💻"), text: "👩🏽‍💻", status: .ready)
        let messages = try payloadMessages(HintRequest(question: nearLimit, previousHint: previous))
        #expect(messages.count == 2)
        #expect(messages.last?["content"] as? String == "Собеседник: " + nearLimit.text)
    }
    private func payloadMessages(_ request: HintRequest) throws -> [[String: Any]] {
        let object = try #require(JSONSerialization.jsonObject(with: PromptBuilder().build(request)) as? [String: Any])
        return try #require(object["messages"] as? [[String: Any]])
    }
}
