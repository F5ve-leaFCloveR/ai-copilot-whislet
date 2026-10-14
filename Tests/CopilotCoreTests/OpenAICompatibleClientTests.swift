import Foundation
import Testing
@testable import CopilotCore

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var chunks: [Data]
        var delay: TimeInterval = 0
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) -> Reply)?
        var requests: [URLRequest] = []
    }
    private static let state = State()
    private var work: Task<Void, Never>?
    static func configure(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.lock.withLock { state.handler = handler; state.requests = [] }
    }
    static var requests: [URLRequest] { state.lock.withLock { state.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let reply = Self.state.lock.withLock {
            Self.state.requests.append(captured)
            return Self.state.handler!(captured)
        }
        work = Task { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks {
                if reply.delay > 0 { try? await Task.sleep(for: .seconds(reply.delay)) }
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard !Task.isCancelled else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { work?.cancel() }
}

@Suite(.serialized)
struct OpenAICompatibleClientTests {
    private func client(timeout: TimeInterval = 1, connection: APIConnection = .legacy) -> OpenAICompatibleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return OpenAICompatibleClient(keyProvider: { "test-only" }, session: URLSession(configuration: configuration), connection: connection, timeout: timeout)
    }
    private func request(_ text: String = "Что такое actor?", connection: APIConnection = .legacy) -> HintRequest {
        HintRequest(question: Utterance(source: .system, text: text, endedAt: 1, isFinal: true), connection: connection)
    }
    private func frame(_ object: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Data("data: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }
    private func response(content: String = #"{"points":["Изоляция состояния","Последовательный доступ","await при обращении"],"followups":[]}"#, finish: String = "stop", usage: Bool = true, done: Bool = true) -> Data {
        var data = frame(["choices": [["delta": ["content": content], "finish_reason": NSNull()]]])
        data.append(frame(["choices": [["delta": [:], "finish_reason": finish]]]))
        if usage { data.append(Data("data: {\"choices\":[],\"usage\":{\"cost_rub\":0.04}}\n\n".utf8)) }
        if done { data.append(Data("data: [DONE]\n\n".utf8)) }
        return data
    }
    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func streamingFinalUsageAndPayload() async throws {
        let body = response()
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { event -> String? in if case .text(_, let text) = event { text } else { nil } }.joined()
        #expect(text == "**Краткий ответ:** Изоляция состояния\n\n**Детализированное объяснение**\nПоследовательный доступ\n\nawait при обращении")
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
        let sent = try #require(FixtureURLProtocol.requests.first)
        #expect(sent.url?.path == "/v1/chat/completions")
        let sentBody = try #require(sent.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(payload["model"] as? String == "claude-haiku-5.5")
        #expect((payload["stream_options"] as? [String: Bool])?["include_usage"] == true)
        #expect(FixtureURLProtocol.requests.count == 1)
    }

    @Test func codeFirstStreamsWithoutProseHeadings() async throws {
        let code = "```python\nclass TimeMap:\n    pass\n```"
        let body = try JSONSerialization.data(withJSONObject: ["points": [code, "Поиск занимает O(log n)."], "followups": ["Покажи граничные случаи"]])
        var wire = Data()
        for character in String(decoding: body, as: UTF8.self) {
            wire.append(frame(["choices": [["delta": ["content": String(character)]]]]))
        }
        wire.append(response(content: ""))
        let reply = wire
        FixtureURLProtocol.configure { _ in .init(chunks: [reply]) }
        let client = client(); let request = request("Реши задачу на изображении")
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { if case .text(_, let value) = $0 { value } else { nil } }.joined()
        #expect(text == code + "\n\nПоиск занимает O(log n).")
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func codeAfterBriefDoesNotGetAnExplanationHeading() async throws {
        let content = #"{"points":["Используем binary search.","```python\nanswer = 42\n```"],"followups":[]}"#
        let body = response(content: content)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { if case .text(_, let value) = $0 { value } else { nil } }.joined()
        #expect(text == "**Краткий ответ:** Используем binary search.\n\n```python\nanswer = 42\n```")
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func unclosedCodeCannotBecomeAReadyAnswer() async throws {
        let content = #"{"points":["```python\nanswer = 42"],"followups":["Покажи пример"]}"#
        let body = response(content: content)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "incomplete"))
        #expect(!events.contains { if case .suggestions = $0 { true } else { false } })
    }

    @Test func answerStreamsBeforeValidatedClarifications() async throws {
        let first = frame(["choices": [["delta": ["content": #"{"points":["Начать с **анализа пропусков**"#]]]])
        let rest = response(content: #"","1. **Проверить кандидатов**\n   - Найти пропущенные документы"],"followups":["Как измерить recall@10?","Как подобрать top-k?"]}"#)
        FixtureURLProtocol.configure { _ in .init(chunks: [first, rest]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let texts = events.compactMap { if case .text(_, let value) = $0 { value } else { nil } }
        #expect(texts.first == "**Краткий ответ:** Начать с **анализа пропусков**")
        let suggestions = events.compactMap { if case .suggestions(_, let values) = $0 { values } else { nil } }
        #expect(suggestions == [["Как измерить recall@10?", "Как подобрать top-k?"]])
        #expect(events.dropLast().last == .suggestions(request.id, ["Как измерить recall@10?", "Как подобрать top-k?"]))
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
        #expect(!texts.joined().contains("Как подобрать top-k?"))
    }

    @Test func missingRequiredFollowupsCannotBeReady() async throws {
        let body = response(content: #"{"points":["Ответ"]}"#)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "incomplete"))
    }

    @Test func incompleteResponseNeverOffersFollowups() async throws {
        let body = response(content: #"{"points":["Ответ"],"followups":["Объясни механизм"]}"#, finish: "length")
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(!events.contains { if case .suggestions = $0 { true } else { false } })
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "incomplete"))
    }

    @Test func missingDoneOrUsageCannotBeReady() async throws {
        for pair in [(false, true), (true, false)] {
            let body = response(usage: pair.1, done: pair.0)
            FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
            let client = client(); let request = request()
            let events = try await collect(await client.generate(request))
            #expect(events.last == .done(request.id, costRub: pair.1 ? Decimal(string: "0.04") : nil, finishReason: "incomplete"))
        }
    }

    @Test func twoPartAnswerDoesNotRequireFillerParagraph() async throws {
        let body = response(content: #"{"points":["Прямой ответ","Понятное объяснение"],"followups":[]}"#)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { if case .text(_, let text) = $0 { text } else { nil } }.joined()
        #expect(text == "**Краткий ответ:** Прямой ответ\n\n**Детализированное объяснение**\nПонятное объяснение")
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func malformedPointsAndLengthCannotBeReady() async throws {
        for body in [response(content: #"{"points":[],"followups":[]}"#), response(content: #"{"points":[""],"followups":[]}"#), response(finish: "length")] {
            FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
            let client = client(); let request = request()
            let events = try await collect(await client.generate(request))
            #expect(!events.contains(.done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop")))
            #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "incomplete"))
        }
    }

    @Test func singlePersonalFactCanFinishWithoutAnExplanation() async throws {
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response(content: #"{"points":["Я редактировал manifests. Результат нужно уточнить."],"followups":[]}"#)]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { if case .text(_, let text) = $0 { text } else { nil } }.joined()
        #expect(text == "**Краткий ответ:** Я редактировал manifests. Результат нужно уточнить.")
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func unknownMarkerSuffixNeverAppearsDuringStreaming() async throws {
        let marker = "Этот кейс не описан в профиле — уточни реальный опыт"
        let first = frame(["choices": [["delta": ["content": "{\"points\":[\"" + marker.dropLast()]]]])
        let second = frame(["choices": [["delta": ["content": String(marker.suffix(1)) + ". Кандидат без практики Kubernetes\",\"Если понадобится, можно составить план"]]]])
        var last = frame(["choices": [["delta": ["content": ".\"],\"followups\":[]}"], "finish_reason": "stop"]]])
        last.append(Data("data: {\"choices\":[],\"usage\":{\"cost_rub\":0.04}}\n\ndata: [DONE]\n\n".utf8))
        let chunks = [first, second, last]
        FixtureURLProtocol.configure { _ in .init(chunks: chunks, delay: 0.01) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        let text = events.compactMap { if case .text(_, let text) = $0 { text } else { nil } }.joined()
        #expect(text == "**Краткий ответ:** " + marker + "\n\n**Детализированное объяснение**\nЕсли понадобится, можно составить план.")
        #expect(!events.contains { if case .text(_, let text) = $0 { text.contains("без практики") } else { false } })
        #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func splitMarkerFailsWithoutReady() async throws {
        let first = frame(["choices": [["delta": ["content": #"{"points":["Ответ </fi"#]]]])
        let second = frame(["choices": [["delta": ["content": #"nal>"#]]]])
        FixtureURLProtocol.configure { _ in .init(chunks: [first, second]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.contains { if case .failed(request.id, _) = $0 { true } else { false } })
        #expect(!events.contains { if case .done(_, _, "stop") = $0 { true } else { false } })
        #expect(!events.contains { if case .text(_, let text) = $0 { text.contains("</fi") } else { false } })
    }

    @Test func unauthorizedIsNotRetried() async throws {
        FixtureURLProtocol.configure { _ in .init(status: 401, chunks: [Data("{}".utf8)]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.contains { if case .failed(request.id, let message) = $0 { message.contains("401") } else { false } })
        #expect(FixtureURLProtocol.requests.count == 1)
    }

    @Test func balanceUsesRubleBudgetWithoutResettingLedger() async throws {
        FixtureURLProtocol.configure { _ in .init(chunks: [Data(#"{"balance":100.25,"budget":20.5}"#.utf8)]) }
        let value = try await client().balance()
        #expect(value.balance == Decimal(string: "100.25"))
        #expect(value.availableRub == Decimal(string: "20.5"))
        #expect(FixtureURLProtocol.requests.first?.url?.path == "/v1/aitunnel/balance")
    }

    @Test func replacementAndExplicitCancellationFinishOldStreams() async throws {
        let body = response()
        FixtureURLProtocol.configure { _ in .init(chunks: [body], delay: 0.1) }
        let client = client(); let first = request(); let second = request("Как работает await?")
        let old = await client.generate(first)
        let new = await client.generate(second)
        let oldEvents = try await collect(old)
        let newEvents = try await collect(new)
        #expect(oldEvents.isEmpty)
        #expect(newEvents.last == .done(second.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
        let cancelled = request(); let stream = await client.generate(cancelled)
        await client.cancel(cancelled.id)
        let events = try await collect(stream)
        #expect(events.isEmpty)
    }

    @Test func alreadyCancelledCallerNeverSendsPOST() async throws {
        let body = response()
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.generate(request)
        }
        let stream = await caller.value
        var cancelled = false
        do { _ = try await collect(stream) }
        catch is CancellationError { cancelled = true }
        #expect(cancelled)
        #expect(FixtureURLProtocol.requests.filter { $0.httpMethod == "POST" }.isEmpty)
    }

    @Test func hardDeadlineStopsStalledStream() async throws {
        let body = response()
        FixtureURLProtocol.configure { _ in .init(chunks: [body], delay: 0.2) }
        let client = client(timeout: 0.02); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.contains { if case .failed(request.id, _) = $0 { true } else { false } })
        #expect(!events.contains { if case .done(_, _, "stop") = $0 { true } else { false } })
    }

    @Test func usageSurvivesCorruptionInSameFrame() async throws {
        let body = Data(#"data: {"usage":{"cost_rub":0.100000000000000001},"choices":[{"delta":{"content":"{\"points\":[\"</final>"}}]}"#.utf8) + Data("\n\n".utf8)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.filter { if case .usage = $0 { true } else { false } } == [.usage(request.id, costRub: Decimal(string: "0.100000000000000001")!)])
        #expect(events.contains { if case .failed(request.id, _) = $0 { true } else { false } })
    }

    @Test func unicodeEscapedServiceMarkerCannotBypassGuard() async throws {
        let body = response(content: #"{"points":["\u003c/final>","B","C"],"followups":[]}"#)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client(); let request = request()
        let events = try await collect(await client.generate(request))
        #expect(events.contains { if case .failed(request.id, _) = $0 { true } else { false } })
        #expect(!events.contains { if case .text(_, let text) = $0 { text.contains("</final>") } else { false } })
    }

    @Test func firstPointIsVisibleBeforeJSONCloses() async throws {
        let first = frame(["choices": [["delta": ["content": #"{"points":["Изоляция"#]]]])
        var last = frame(["choices": [["delta": ["content": #" состояния","Последовательный доступ","await при обращении"],"followups":[]}"#], "finish_reason": "stop"]]])
        last.append(Data("data: {\"choices\":[],\"usage\":{\"cost_rub\":0.04}}\n\ndata: [DONE]\n\n".utf8))
        let chunks = [first, last]
        FixtureURLProtocol.configure { _ in .init(chunks: chunks, delay: 0.01) }
        let client = client(); let request = request()
        var iterator = (await client.generate(request)).makeAsyncIterator()
        #expect(try await iterator.next() == .text(request.id, "**Краткий ответ:** Изоляция"))
        var rest: [GenerationEvent] = []
        while let event = try await iterator.next() { rest.append(event) }
        #expect(rest.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
    }

    @Test func splitCombiningMarkAndZWJKeepValidStreamingText() async throws {
        for (base, suffix) in [("е", "\u{0301}"), ("👩", "\u{200D}💻")] {
            let first = frame(["choices": [["delta": ["content": "{\"points\":[\"" + base]]]])
            var last = frame(["choices": [["delta": ["content": suffix + " текст\",\"B\",\"C\"],\"followups\":[]}"], "finish_reason": "stop"]]])
            last.append(Data("data: {\"choices\":[],\"usage\":{\"cost_rub\":0.04}}\n\ndata: [DONE]\n\n".utf8))
            let chunks = [first, last]
            FixtureURLProtocol.configure { _ in .init(chunks: chunks, delay: 0.001) }
            let client = client(); let request = request()
            let events = try await collect(await client.generate(request))
            let text = events.compactMap { if case .text(_, let text) = $0 { text } else { nil } }.joined()
            #expect(text == "**Краткий ответ:** " + base + suffix + " текст\n\n**Детализированное объяснение**\nB\n\nC")
            #expect(events.last == .done(request.id, costRub: Decimal(string: "0.04"), finishReason: "stop"))
        }
    }

    @Test func imageBelongsToOneRequestAndLongResponseAllowsHTML() async throws {
        let body = response(content: "<div>код</div>")
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let client = client()
        let preset = ModelPreset(maxTokens: 1536, structuredShort: false)
        let image = HintRequest(question: request().question, preset: preset, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        let first = try await collect(await client.generate(image))
        #expect(first.contains(.text(image.id, "<div>код</div>")))
        let plain = HintRequest(question: request().question, preset: preset)
        _ = try await collect(await client.generate(plain))
        let sent = FixtureURLProtocol.requests
        #expect(sent.count == 2)
        let imageBody = try #require(sent[0].httpBody)
        let plainBody = try #require(sent[1].httpBody)
        let imageJSON = String(decoding: imageBody, as: UTF8.self)
        let plainJSON = String(decoding: plainBody, as: UTF8.self)
        #expect(imageJSON.contains("image_url"))
        #expect(!plainJSON.contains("image_url"))
        #expect(!plainJSON.contains("response_format"))
    }

    @Test func standardStreamingFinishesWithoutMonetaryUsage() async throws {
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response(usage: false)]) }
        let request = request(connection: .openAI)
        let events = try await collect(await client(connection: .openAI).generate(request))
        #expect(events.last == .done(request.id, costRub: nil, finishReason: "stop"))
        #expect(!events.contains { if case .usage = $0 { true } else { false } })
        #expect(!events.contains { if case .pricedUsage = $0 { true } else { false } })
        let sent = try #require(FixtureURLProtocol.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(sent.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func routerDollarUsageIsNotReportedAsRubles() async throws {
        let body = response(usage: false, done: false) + Data("data: {\"choices\":[],\"usage\":{\"cost\":\"0.000123000000000001\",\"cost_rub\":9}}\n\ndata: [DONE]\n\n".utf8)
        FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
        let request = request(connection: .openRouter)
        let events = try await collect(await client(connection: .openRouter).generate(request))
        #expect(events.contains(.pricedUsage(request.id, UsageCost(amount: Decimal(string: "0.000123000000000001")!, currency: "USD"))))
        #expect(!events.contains { if case .usage = $0 { true } else { false } })
        #expect(events.last == .done(request.id, costRub: nil, finishReason: "stop"))
        #expect(FixtureURLProtocol.requests.first?.url?.host == "openrouter.ai")
    }

    @Test func genericGatewayUsesExplicitEndpointAndIgnoresUnknownCurrency() async throws {
        let connection = try APIConnection.resolve(apiKey: "sk-or-test", explicitBaseURL: "https://gateway.example/custom/v1")
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response()]) }
        let request = request(connection: connection)
        let events = try await collect(await client(connection: connection).generate(request))
        #expect(events.last == .done(request.id, costRub: nil, finishReason: "stop"))
        #expect(!events.contains { if case .usage = $0 { true } else { false } })
        #expect(FixtureURLProtocol.requests.first?.url?.absoluteString == "https://gateway.example/custom/v1/chat/completions")
    }

    @Test func schemaSwitchDoesNotDisableStructuredParser() async throws {
        let connection = try APIConnection(baseURL: "https://gateway.example/v1", strictSchema: false)
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response(usage: false)]) }
        let request = request(connection: connection)
        let events = try await collect(await client(connection: connection).generate(request))
        #expect(events.last == .done(request.id, costRub: nil, finishReason: "stop"))
        let data = try #require(FixtureURLProtocol.requests.first?.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["response_format"] == nil)
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response(content: #"{"points":["Answer"]}"#, usage: false)]) }
        let invalid = try await collect(await client(connection: connection).generate(request))
        #expect(invalid.last == .done(request.id, costRub: nil, finishReason: "incomplete"))
    }

    @Test func genericFinishStillRequiresDoneStopAndValidOutput() async throws {
        for body in [response(usage: false, done: false), response(finish: "length", usage: false), response(content: #"{"points":[],"followups":[]}"#, usage: false)] {
            FixtureURLProtocol.configure { _ in .init(chunks: [body]) }
            let request = request(connection: .openAI)
            let events = try await collect(await client(connection: .openAI).generate(request))
            #expect(events.last == .done(request.id, costRub: nil, finishReason: "incomplete"))
            #expect(!events.contains { if case .suggestions = $0 { true } else { false } })
        }
    }

    @Test func genericMalformedSSECannotFinish() async throws {
        FixtureURLProtocol.configure { _ in .init(chunks: [Data("data: {broken}\n\ndata: [DONE]\n\n".utf8)]) }
        let request = request(connection: .openRouter)
        let events = try await collect(await client(connection: .openRouter).generate(request))
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(!events.contains { if case .done(_, _, "stop") = $0 { true } else { false } })
    }

    @Test func unsupportedBalanceAndMismatchedConnectionSendNoCredentials() async throws {
        FixtureURLProtocol.configure { _ in .init(chunks: [self.response()]) }
        do { _ = try await client(connection: .openRouter).balance(); Issue.record("Unexpected balance request") }
        catch { #expect(error as? APIConnectionError == .unsupportedBalance) }
        let request = request(connection: .openRouter)
        let events = try await collect(await client(connection: .openAI).generate(request))
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(FixtureURLProtocol.requests.isEmpty)
    }
}
