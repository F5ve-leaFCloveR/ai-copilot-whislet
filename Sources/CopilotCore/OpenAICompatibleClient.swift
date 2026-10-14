import Foundation


public enum APIClientError: Error, LocalizedError, Sendable {
    case http(Int), invalidResponse, missingKey
    public var errorDescription: String? {
        switch self {
        case .http(let status): "Провайдер вернул HTTP \(status)"
        case .invalidResponse: "Некорректный ответ провайдера"
        case .missingKey: "Добавьте API key в настройках"
        }
    }
}

public actor OpenAICompatibleClient {
    private let keyProvider: @Sendable () throws -> String
    private let session: URLSession
    private let connection: APIConnection
    private let redirectGuard: OriginRedirectGuard
    private let timeout: TimeInterval
    private var activeID: UUID?
    private var activeToken: UUID?
    private var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private var generationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var networkTask: URLSessionTask?

    public init(keyProvider: @escaping @Sendable () throws -> String, session: URLSession? = nil, connection: APIConnection = .legacy, timeout: TimeInterval = 20) {
        self.keyProvider = keyProvider; self.session = session ?? Self.privateSession(); self.connection = connection
        self.redirectGuard = OriginRedirectGuard(connection: connection)
        self.timeout = min(20, max(0.01, timeout))
    }

    public func generate(_ request: HintRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard !Task.isCancelled else {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        invalidate()
        let token = UUID()
        let pair = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        activeID = request.id; activeToken = token; continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(token: token) }
        }
        generationTask = Task { await perform(request, token: token) }
        let timeout = self.timeout
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            await self?.expire(token: token)
        }
        return pair.stream
    }

    public func cancel(_ id: UUID) {
        guard activeID == id else { return }
        invalidate()
    }

    public func balance() async throws -> BalanceSnapshot {
        guard connection.supportsBalance else { throw APIConnectionError.unsupportedBalance }
        let request = try authorizedRequest(path: "aitunnel/balance", method: "GET")
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        try validate(response)
        guard let object = try? JSONDecoder().decode(BalanceBody.self, from: data),
              object.balance.value >= 0 else { throw APIClientError.invalidResponse }
        let balance = object.balance.value
        let budget = object.budget?.value
        if let budget, budget < 0 { throw APIClientError.invalidResponse }
        return BalanceSnapshot(balance: balance, budget: budget)
    }

    private func perform(_ request: HintRequest, token: UUID) async {
        guard activeToken == token, !Task.isCancelled else { return }
        var state = OutputState(structured: request.usesStructuredOutput, connection: connection)
        var emittedUsage = false
        do {
            guard request.connection == connection else { throw APIConnectionError.mismatchedConnection }
            var http = try authorizedRequest(path: "chat/completions", method: "POST")
            http.httpBody = try PromptBuilder().build(request)
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard activeToken == token, !Task.isCancelled else { return }
            let (bytes, response) = try await session.bytes(for: http, delegate: redirectGuard)
            guard activeToken == token, !Task.isCancelled else { bytes.task.cancel(); return }
            networkTask = bytes.task
            try validate(response)
            var decoder = SSEDecoder()
            var line = Data()
            for try await byte in bytes {
                guard activeToken == token, !Task.isCancelled else { return }
                line.append(byte)
                guard line.count <= 262_144 else { throw StreamDecodeError.oversizedFrame }
                if byte == 10 {
                    let events = try decoder.feed(line); line.removeAll(keepingCapacity: true)
                    for event in events {
                        switch event {
                        case .data(let json):
                            let output = try state.consume(json, requestID: request.id)
                            for value in output {
                                switch value { case .usage, .pricedUsage: emittedUsage = true; default: break }
                                emit(value, token: token)
                            }
                        case .done:
                            let output = try state.finish(requestID: request.id, sawDone: true)
                            for value in output { emit(value, token: token) }
                            invalidate(); return
                        }
                    }
                }
            }
            guard activeToken == token, !Task.isCancelled else { return }
            let output = try state.finish(requestID: request.id, sawDone: false)
            for value in output { emit(value, token: token) }
            invalidate()
        } catch {
            guard activeToken == token, !Task.isCancelled else { return }
            if !emittedUsage, let usage = state.usageEvent(requestID: request.id) { emit(usage, token: token) }
            let message: String
            if error is StreamDecodeError {
                message = "Повреждённый ответ модели · повторите запрос"
            } else if let error = error as? APIClientError {
                message = error.localizedDescription
            } else if let error = error as? APIConnectionError {
                message = error.localizedDescription
            } else if let error = error as? PromptError {
                message = error.localizedDescription
            } else { message = "Не удалось получить ответ · проверьте соединение" }
            emit(.failed(request.id, message), token: token)
            invalidate()
        }
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        let key = try keyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIClientError.missingKey }
        var request = URLRequest(url: connection.baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, let url = http.url, connection.accepts(url) else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIClientError.http(http.statusCode) }
    }
    private func emit(_ event: GenerationEvent, token: UUID) {
        guard activeToken == token else { return }
        continuation?.yield(event)
    }
    private func cancel(token: UUID) {
        guard activeToken == token else { return }
        invalidate()
    }
    private func expire(token: UUID) {
        guard activeToken == token, let id = activeID else { return }
        emit(.failed(id, "Превышено время ожидания ответа"), token: token)
        invalidate()
    }
    private func invalidate() {
        activeID = nil; activeToken = nil
        let pending = continuation; continuation = nil
        generationTask?.cancel(); generationTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        networkTask?.cancel(); networkTask = nil
        pending?.finish()
    }
    private struct Money: Decodable {
        let value: Decimal
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self),
               let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN { self.value = value }
            else { value = try container.decode(Decimal.self) }
        }
    }
    private struct BalanceBody: Decodable { let balance: Money; let budget: Money? }
    private struct UsageEnvelope: Decodable {
        struct Usage: Decodable {
            let costRub: Money?
            let cost: Money?
            enum CodingKeys: String, CodingKey { case costRub = "cost_rub", cost }
        }
        let usage: Usage?
    }

    private struct OutputState {
        let structured: Bool
        let connection: APIConnection
        var parser = IncrementalHintDecoder(requireFollowups: true)
        var rawGuard = ContentGuard()
        var displayGuard = ContentGuard()
        var invalidSchema = false
        var presented = ""
        var finishReason: String?
        var cost: Decimal?
        var pricedCost: UsageCost?
        var usageEmitted = false
        var hasText = false
        init(structured: Bool, connection: APIConnection) { self.structured = structured; self.connection = connection }

        func usageEvent(requestID: UUID) -> GenerationEvent? {
            if let cost { return .usage(requestID, costRub: cost) }
            if let pricedCost { return .pricedUsage(requestID, pricedCost) }
            return nil
        }

        mutating func consume(_ json: String, requestID: UUID) throws -> [GenerationEvent] {
            guard let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StreamDecodeError.malformedJSON }
            guard object["error"] == nil else { throw APIClientError.invalidResponse }
            var events: [GenerationEvent] = []
            let usage = try? JSONDecoder().decode(UsageEnvelope.self, from: data).usage
            if connection.dialect == .legacyGateway, let value = usage?.costRub?.value ?? usage?.cost?.value, !value.isNaN, value >= 0 {
                cost = value
            } else if connection.dialect == .openRouter, let value = usage?.cost?.value, !value.isNaN, value >= 0 {
                pricedCost = UsageCost(amount: value, currency: "USD")
            }
            if !usageEmitted, let event = usageEvent(requestID: requestID) {
                events.append(event); usageEmitted = true
            }
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
                guard let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty else { continue }
                _ = rawGuard.accept(text)
                guard !rawGuard.isCorrupt else { throw StreamDecodeError.corruptMarker }
                events += try accept(rawGuard.acceptedText, requestID: requestID)
            }
            return events
        }

        mutating func accept(_ text: String, requestID: UUID) throws -> [GenerationEvent] {
            guard !text.isEmpty else { return [] }
            let delta: String
            if structured {
                guard !invalidSchema else { return [] }
                let points: [String]
                do { points = try parser.feed(text) }
                catch { invalidSchema = true; return [] }
                var display = ""
                var startsWithCode = false
                if let first = points.first {
                    let answer = String(first.drop(while: { $0.isWhitespace }))
                    let marker = "Этот кейс не описан в профиле — уточни реальный опыт"
                    startsWithCode = answer.hasPrefix("```")
                    if !answer.isEmpty, !("```".hasPrefix(answer)) {
                        display = startsWithCode ? answer : "**Краткий ответ:** " + (answer.hasPrefix(marker) ? marker : answer)
                    }
                }
                if points.count > 1, !points[1].isEmpty {
                    let explanation = points[1]
                    if !("```".hasPrefix(explanation)) {
                        display += startsWithCode || explanation.hasPrefix("```") ? "\n\n" + explanation : "\n\n**Детализированное объяснение**\n" + explanation
                    }
                }
                if points.count > 2, !points[2].isEmpty { display += "\n\n" + points[2] }
                guard display.unicodeScalars.starts(with: presented.unicodeScalars) else { invalidSchema = true; return [] }
                delta = String(display.unicodeScalars.dropFirst(presented.unicodeScalars.count)); presented = display
            } else { delta = text }
            _ = displayGuard.accept(delta)
            guard !displayGuard.isCorrupt else { throw StreamDecodeError.corruptMarker }
            if !displayGuard.acceptedText.isEmpty { hasText = true }
            return displayGuard.acceptedText.isEmpty ? [] : [.text(requestID, displayGuard.acceptedText)]
        }

        mutating func finish(requestID: UUID, sawDone: Bool) throws -> [GenerationEvent] {
            var events = try accept(rawGuard.finish(), requestID: requestID)
            if structured {
                do { _ = try parser.finish() }
                catch { invalidSchema = true }
            }
            let tail = try displayGuard.finish()
            if !tail.isEmpty { hasText = true; events.append(.text(requestID, tail)) }
            let valid = sawDone && (!connection.requiresCost || cost != nil) && finishReason == "stop" && !invalidSchema && hasText
            if valid, structured, !parser.followups.isEmpty { events.append(.suggestions(requestID, parser.followups)) }
            events.append(.done(requestID, costRub: cost, finishReason: valid ? "stop" : "incomplete"))
            return events
        }
    }

    private static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }
}

private final class OriginRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let connection: APIConnection
    init(connection: APIConnection) { self.connection = connection }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(connection.accepts) == true ? request : nil)
    }
}
