import Foundation

public enum AudioSource: String, Codable, Sendable { case system, microphone }
public enum ConversationMode: String, Codable, Sendable { case interview, work, recruiterInterview }

public struct Utterance: Codable, Equatable, Sendable {
    public let id: UUID
    public let source: AudioSource
    public let text: String
    public let endedAt: Double
    public let isFinal: Bool
    public init(id: UUID = UUID(), source: AudioSource, text: String, endedAt: Double, isFinal: Bool) {
        self.id = id; self.source = source; self.text = text; self.endedAt = endedAt; self.isFinal = isFinal
    }
}

public enum HintStatus: Equatable, Sendable {
    case waiting, streaming, ready, cancelled, incomplete, failed(String)
}

public struct HintCard: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let question: Utterance
    public var text: String
    public var followups: [String] = []
    public var status: HintStatus
    public var imageCapturedAt: Double?
    public init(id: UUID, question: Utterance, text: String = "", status: HintStatus = .waiting, imageCapturedAt: Double? = nil) {
        self.id = id; self.question = question; self.text = text; self.status = status; self.imageCapturedAt = imageCapturedAt
    }
}

public struct ModelPreset: Codable, Equatable, Sendable {
    public let model: String
    public let reasoningEffort: String?
    public let providerSort: String
    public let maxTokens: Int
    public let structuredShort: Bool
    public init(model: String = "claude-haiku-5.5", reasoningEffort: String? = "none", providerSort: String = "latency", maxTokens: Int = 2048, structuredShort: Bool = true) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.providerSort = providerSort; self.maxTokens = maxTokens; self.structuredShort = structuredShort
    }
    public static let short = ModelPreset()
    public static func defaultReasoningEffort(for model: String) -> String? {
        let model = model.lowercased()
        if model.hasPrefix("gemini-3.") || model.hasPrefix("gemini-3-") { return "minimal" }
        if model.hasPrefix("gemini-2.5") { return nil }
        if model.hasPrefix("gpt-4.1") { return nil }
        return "none"
    }
}

public struct HintRequest: Sendable {
    public let id: UUID
    public let question: Utterance
    public let context: [Utterance]
    public let profile: String
    public let preset: ModelPreset
    public let jpeg: Data?
    public let previousHint: HintCard?
    public let mode: ConversationMode
    public let projectContext: String
    public let connection: APIConnection
    public var usesStructuredOutput: Bool { preset.structuredShort && mode != .recruiterInterview }
    public init(id: UUID = UUID(), question: Utterance, context: [Utterance] = [], profile: String = "", preset: ModelPreset = .short, jpeg: Data? = nil, previousHint: HintCard? = nil, mode: ConversationMode = .interview, projectContext: String = "", connection: APIConnection = .legacy) {
        self.id = id; self.question = question; self.context = context; self.profile = profile; self.preset = preset; self.jpeg = jpeg; self.previousHint = previousHint; self.mode = mode; self.projectContext = projectContext
        self.connection = connection
    }
    public static func clarificationContext(for text: String?, screenshot: Bool = false, selectedCard: HintCard?) -> HintCard? {
        guard !screenshot, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selectedCard
    }
}

public struct UsageCost: Equatable, Sendable {
    public let amount: Decimal
    public let currency: String
    public init(amount: Decimal, currency: String) { self.amount = amount; self.currency = currency }
}

public enum GenerationEvent: Equatable, Sendable {
    case text(UUID, String)
    case suggestions(UUID, [String])
    case usage(UUID, costRub: Decimal)
    case pricedUsage(UUID, UsageCost)
    case done(UUID, costRub: Decimal?, finishReason: String)
    case failed(UUID, String)
    public var id: UUID {
        switch self { case .text(let id, _), .suggestions(let id, _), .usage(let id, _), .pricedUsage(let id, _), .done(let id, _, _), .failed(let id, _): return id }
    }
}

public enum ShareMode: String, Codable, Sendable { case none, window, fullDisplay }
public struct BalanceSnapshot: Equatable, Sendable {
    public let balance: Decimal
    public let budget: Decimal?
    public init(balance: Decimal, budget: Decimal? = nil) { self.balance = balance; self.budget = budget }
    public var availableRub: Decimal { min(balance, budget ?? balance) }
}
