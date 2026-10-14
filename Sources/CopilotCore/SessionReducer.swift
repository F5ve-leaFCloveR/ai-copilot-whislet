import Foundation

public struct SessionReducer: Sendable {
    public private(set) var activeRequestID: UUID?
    public private(set) var selectedCardID: UUID?
    public private(set) var pendingCardID: UUID?
    public private(set) var isReadingHistory = false
    public private(set) var isPaused = false
    public private(set) var isHidden = false
    public private(set) var isRunning = true
    public private(set) var cards: [HintCard] = []
    public private(set) var transcript: [Utterance] = []
    public var latestCard: HintCard? { cards.last }
    public var selectedCard: HintCard? { cards.first { $0.id == selectedCardID } }
    public init() {}
    public mutating func begin(question: Utterance) -> UUID {
        let id = UUID()
        guard isRunning, !isPaused, !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return id }
        cancelActive()
        cards.append(HintCard(id: id, question: question, status: .streaming))
        activeRequestID = id
        selectedCardID = id
        pendingCardID = nil
        isReadingHistory = false
        return id
    }
    public mutating func apply(_ event: GenerationEvent) {
        guard event.id == activeRequestID, let index = cards.firstIndex(where: { $0.id == event.id }) else { return }
        switch event {
        case .text(_, let chunk): cards[index].text += chunk
        case .suggestions(_, let values): cards[index].followups = values
        case .usage, .pricedUsage: break
        case .done(_, _, let reason):
            cards[index].status = reason == "stop" ? .ready : .incomplete
            cards[index].imageCapturedAt = nil
            activeRequestID = nil
        case .failed(_, let message):
            cards[index].status = .failed(message)
            cards[index].imageCapturedAt = nil
            activeRequestID = nil
        }
    }
    public mutating func selectHistory(_ id: UUID) {
        guard cards.contains(where: { $0.id == id }) else { return }
        selectedCardID = id; isReadingHistory = true
    }
    public mutating func showLatest() { selectedCardID = latestCard?.id; pendingCardID = nil; isReadingHistory = false }
    public mutating func pause() { isPaused = true; cancelActive() }
    public mutating func cancel() { cancelActive() }
    public mutating func resume() { isRunning = true; isPaused = false }
    public mutating func hide() { isHidden = true }
    public mutating func show() { isHidden = false }
    public mutating func resetConversation() {
        cancelActive(); cards.removeAll(); transcript.removeAll()
        selectedCardID = nil; pendingCardID = nil; isReadingHistory = false
    }
    public mutating func stop() {
        cancelActive(); cards.removeAll(); transcript.removeAll()
        selectedCardID = nil; pendingCardID = nil; isReadingHistory = false
        isRunning = false; isPaused = false; isHidden = false
    }
    public mutating func appendTranscript(_ utterance: Utterance) {
        if let index = transcript.firstIndex(where: { $0.id == utterance.id }) { transcript[index] = utterance }
        else { transcript.append(utterance) }
        if transcript.count > 100 { transcript.removeFirst(transcript.count - 100) }
    }
    private mutating func cancelActive() {
        if let id = activeRequestID, let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].status = .cancelled; cards[index].imageCapturedAt = nil
        }
        activeRequestID = nil
    }
}
