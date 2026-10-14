import Foundation

public struct ManualQuestionSelection: Equatable, Sendable {
    public let question: Utterance
    public let context: [Utterance]
}

public enum ManualQuestionSelector {
    public static func select(from utterances: [Utterance]) -> ManualQuestionSelection? {
        var unique: [UUID: Utterance] = [:]
        for utterance in utterances where !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let previous = unique[utterance.id] {
                if utterance.endedAt < previous.endedAt { continue }
                if utterance.endedAt == previous.endedAt, previous.isFinal, !utterance.isFinal { continue }
            }
            unique[utterance.id] = utterance
        }
        let context = unique.values.sorted { left, right in
            if left.endedAt != right.endedAt { return left.endedAt < right.endedAt }
            if left.source != right.source { return left.source == .system }
            if left.isFinal != right.isFinal { return !left.isFinal }
            return left.id.uuidString < right.id.uuidString
        }
        guard let question = context.last else { return nil }
        return ManualQuestionSelection(question: question, context: context)
    }
}
