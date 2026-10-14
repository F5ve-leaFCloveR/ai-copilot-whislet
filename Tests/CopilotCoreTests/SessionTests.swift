import Foundation
import Testing
@testable import CopilotCore

func remoteQuestion(_ text: String) -> Utterance {
    Utterance(source: .system, text: text, endedAt: 0, isFinal: true)
}

@Suite struct SessionTests {
    @Test func followupsStayWithTheirAnswerAndIgnoreLateGenerations() {
        var state = SessionReducer()
        let first = state.begin(question: remoteQuestion("Зачем reranker?"))
        state.apply(.text(first, "Пересортировать кандидатов"))
        state.apply(.suggestions(first, ["Как проверить пользу?"]))
        state.apply(.done(first, costRub: 0, finishReason: "stop"))
        let second = state.begin(question: remoteQuestion("Что такое recall?"))
        #expect(state.selectedCard?.followups.isEmpty == true)
        state.apply(.suggestions(first, ["Просроченное уточнение"]))
        state.apply(.suggestions(second, ["Как выбрать k?"]))
        state.selectHistory(first)
        #expect(state.selectedCard?.followups == ["Как проверить пользу?"])
        let context = HintRequest.clarificationContext(for: "Как проверить пользу?", selectedCard: state.selectedCard)
        #expect(context?.question.text == "Зачем reranker?")
        state.showLatest()
        #expect(state.selectedCard?.followups == ["Как выбрать k?"])
    }

    @Test func conversationalFormsAndDirectRequestsAreQuestions() {
        let questions = [
            "Какое количество потоков обрабатывает сервис",
            "С какими моделями вы сравнивали качество",
            "Хорошо, расскажи как вы оценивали ответ",
            "Ну тогда если можешь опиши архитектуру очереди",
            "Давай, поясни принцип изоляции",
            "Расскажите про ограничения этого подхода",
            "Про обработку данных, что конкретно ты проверял",
            "Про хранилище, что у вас используется под капотом",
            "Ты с этой оценкой согласен или считаешь её завышенной",
            "У нас есть несколько вариантов. А как вы выбрали модель",
            "Okay, please describe the queue architecture",
            "Could you explain how the cache expires",
            "What kind of failures should we expect",
            "About the implementation, what exactly did you change"
        ]
        for text in questions {
            var gate = QuestionGate()
            let accepted = gate.accept(remoteQuestion(text))
            #expect(accepted, "Не распознан прямой запрос: \(text)")
        }
    }

    @Test func statementsWithQuestionWordsAreNotQuestions() {
        let statements = [
            "Я знаю как это работает",
            "Как правило, используют кеш",
            "Ну, как правило, используют кеш",
            "Что я сделал — настроил кеш",
            "Я объяснил почему нужен индекс",
            "Я понимаю, как ты это обрабатываешь",
            "Он рассказал, что вы выбрали другую модель",
            "Я предложил учесть, что ты можешь выполнять запросы",
            "Какие-то сервисы используют кеш",
            "Как-то так",
            "Можно было задать вопросы",
            "Рассказываю как работает очередь",
            "I know how you implemented the cache",
            "What I did was add a cache",
            "As a rule, this runs in one thread"
        ]
        for text in statements {
            var gate = QuestionGate()
            let accepted = gate.accept(remoteQuestion(text))
            #expect(!accepted, "Утверждение принято за вопрос: \(text)")
        }
    }

    @Test func extendedCuesStillRequireFinalSystemSpeechAndDeduplicate() {
        let text = "Хорошо, расскажите про очередь"
        var gate = QuestionGate()
        let mic = gate.accept(Utterance(source: .microphone, text: text, endedAt: 0, isFinal: true))
        let partial = gate.accept(Utterance(source: .system, text: text, endedAt: 0, isFinal: false))
        #expect(!mic && !partial)
        let final = remoteQuestion(text)
        let first = gate.accept(final)
        let repeatedID = gate.accept(final)
        let repeatedText = gate.accept(remoteQuestion("  ХОРОШО,   расскажите про очередь  "))
        #expect(first && !repeatedID && !repeatedText)
        gate.reset()
        let afterReset = gate.accept(final)
        #expect(afterReset)
    }

    @Test func parentheticalAndRelativeClausesStayStatements() {
        let statements = [
            "Я как ты видишь просто решил попробовать посмотреть, что он сам про это думает",
            "Мы, как вы заметили, уже внедрили пул соединений",
            "I did what you recommended",
            "They reviewed what you implemented",
            "Я хотел не спросить, как вы выбрали модель, а проверить логи"
        ]
        for text in statements {
            var gate = QuestionGate()
            let accepted = gate.accept(remoteQuestion(text))
            #expect(!accepted, "Относительная clause принята за вопрос: \(text)")
        }
        let questions = [
            "Я хотел спросить, как вы выбрали модель",
            "Мы хотим уточнить, почему вы применили индекс",
            "Я закончил описание. Как вы проверяете ответ"
        ]
        for text in questions {
            var gate = QuestionGate()
            let accepted = gate.accept(remoteQuestion(text))
            #expect(accepted, "Не распознан явный запрос: \(text)")
        }
    }

    @Test func hiddenNewGenerationAndCancelKeepListening() {
        var state = SessionReducer()
        state.hide()
        let id = state.begin(question: remoteQuestion("Как работает await?"))
        #expect(state.isHidden)
        state.apply(.usage(id, costRub: 1))
        #expect(state.activeRequestID == id)
        state.cancel()
        #expect(!state.isPaused)
        #expect(state.isRunning)
        #expect(state.latestCard?.status == .cancelled)
        state.apply(.done(id, costRub: 1, finishReason: "stop"))
        #expect(state.latestCard?.status == .cancelled)
    }
    @Test func testOwnPartialSilentAndDuplicateSpeechCannotTrigger() {
        var gate = QuestionGate()
        let accepted1 = !(gate.accept(Utterance(source: .microphone, text: "Как работает RAG?", endedAt: 1, isFinal: true)))
        #expect(accepted1)
        let accepted2 = !(gate.accept(Utterance(source: .system, text: "Как работает RAG?", endedAt: 1, isFinal: false)))
        #expect(accepted2)
        let accepted3 = !(gate.accept(remoteQuestion("  ")))
        #expect(accepted3)
        let question = remoteQuestion("Как работает RAG?")
        let accepted4 = gate.accept(question)
        #expect(accepted4)
        let accepted5 = !(gate.accept(question))
        #expect(accepted5)
        let accepted6 = !(gate.accept(remoteQuestion("  КАК   работает RAG? ")))
        #expect(accepted6)
        let accepted7 = gate.accept(remoteQuestion("почему?"))
        #expect(accepted7)
    }
    @Test func testLateAnswerCannotReplaceNewQuestion() {
        var state = SessionReducer()
        let first = state.begin(question: remoteQuestion("Что такое RAG?"))
        let second = state.begin(question: remoteQuestion("Зачем reranker?"))
        state.apply(.text(first, "старый ответ"))
        state.apply(.text(second, "новый ответ"))
        #expect(state.latestCard?.text == "новый ответ")
        #expect(state.cards.first?.status == .cancelled)
    }
    @Test func newAnswerReplacesHistorySelectionWithoutUnhidingWindows() {
        var state = SessionReducer()
        let first = state.begin(question: remoteQuestion("Первый?"))
        state.apply(.done(first, costRub: nil, finishReason: "stop"))
        state.selectHistory(first)
        state.hide()
        let second = state.begin(question: remoteQuestion("Второй?"))
        state.apply(.text(second, "Новый текст"))
        #expect(state.selectedCardID == second)
        #expect(state.pendingCardID == nil)
        #expect(!state.isReadingHistory)
        #expect(state.selectedCard?.text == "Новый текст")
        #expect(state.isHidden)
    }
    @Test func testPauseCancelsButHideKeepsRequestAndStopClearsData() {
        var state = SessionReducer()
        let id = state.begin(question: remoteQuestion("Вопрос?"))
        state.hide()
        #expect(state.activeRequestID == id)
        state.pause()
        #expect(state.activeRequestID == nil)
        state.apply(.text(id, "Запоздавший"))
        #expect(state.latestCard?.text == "")
        state.stop()
        #expect(state.cards.isEmpty)
        #expect(state.transcript.isEmpty)
        #expect(state.selectedCardID == nil)
    }
    @Test func testLengthFinishIsNeverReady() {
        var state = SessionReducer()
        let id = state.begin(question: remoteQuestion("Вопрос?"))
        state.apply(.done(id, costRub: nil, finishReason: "length"))
        #expect(state.latestCard?.status == .incomplete)
    }
}
