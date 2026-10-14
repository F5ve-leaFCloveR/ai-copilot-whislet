import Foundation
import CopilotCore

actor ProjectContextStore {
    private var cached: [String: (Date?, ProjectKnowledge)] = [:]

    func context(path: String?, question: String, recent: [Utterance], previousHint: HintCard?) throws -> String {
        guard let path, !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: path)
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let knowledge: ProjectKnowledge
        if let existing = cached[path], existing.0 == date { knowledge = existing.1 }
        else {
            knowledge = try ProjectKnowledge.load(from: url)
            cached[path] = (date, knowledge)
        }
        var context = recent.suffix(12).map(\.text).joined(separator: "\n")
        if let previousHint { context += "\n" + previousHint.question.text }
        return knowledge.select(question: question, recentContext: context).text
    }
}
