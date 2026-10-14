import Foundation

public struct QuestionGate: Sendable {
    private var recent: [(UUID, String)] = []
    public init() {}
    public mutating func accept(_ utterance: Utterance) -> Bool {
        guard utterance.source == .system, utterance.isFinal else { return false }
        let text = utterance.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count >= 3, !recent.contains(where: { $0.0 == utterance.id || $0.1 == text }) else { return false }
        guard text.contains("?") || Self.questionClauses(utterance.text).contains(where: Self.isQuestionClause) else { return false }
        recent.append((utterance.id, text))
        if recent.count > 32 { recent.removeFirst(recent.count - 32) }
        return true
    }
    public mutating func reset() { recent.removeAll() }
    public static func referencesScreen(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return ["на экране", "этот код", "смотри схему", "на скриншоте", "on screen", "this code", "this diagram", "screenshot"].contains { normalized.contains($0) }
    }

    private static let fillers: Set<String> = ["ну", "вот", "да", "а", "так", "итак", "ок", "окей", "хорошо", "ладно", "тогда", "собственно", "давай", "давайте", "пожалуйста", "well", "okay", "ok", "so", "right", "then", "please", "and", "but"]
    private static let interrogatives: Set<String> = ["как", "почему", "зачем", "что", "чем", "чего", "чему", "кто", "кого", "кому", "кем", "какой", "какая", "какое", "какие", "какого", "какому", "каким", "какую", "каких", "какими", "чей", "чья", "чье", "чьё", "чьи", "когда", "где", "куда", "откуда", "сколько", "насколько", "how", "why", "what", "which", "who", "whose", "when", "where"]
    private static let imperatives: Set<String> = ["расскажи", "расскажите", "объясни", "объясните", "реши", "решите", "напиши", "напишите", "опиши", "опишите", "покажи", "покажите", "поясни", "поясните", "сравни", "сравните", "назови", "назовите", "приведи", "приведите", "выбери", "выберите", "построй", "постройте", "обоснуй", "обоснуйте", "оцени", "оцените", "скажи", "скажите", "tell", "explain", "solve", "implement", "write", "describe", "show", "compare", "give", "choose", "evaluate"]
    private static let prepositions: Set<String> = ["в", "на", "с", "о", "об", "по", "для", "из", "у", "от", "про", "к", "за", "до", "in", "on", "with", "for", "about", "to", "from", "at"]
    private static let addresses: Set<String> = ["ты", "вы", "тебя", "вас", "тебе", "вам", "you", "your"]
    private static let narrativeSubjects: Set<String> = ["я", "мы", "он", "она", "оно", "они", "i", "we", "he", "she", "it", "they"]
    private static let reported: Set<String> = ["знаю", "знаем", "знаешь", "знаете", "понимаю", "понимаем", "понял", "поняли", "объяснил", "объяснила", "объяснили", "рассказал", "рассказала", "рассказали", "сказал", "сказала", "сказали", "показал", "показала", "показали", "предложил", "предложила", "предложили", "думаю", "думаем", "думал", "помню", "помним", "видел", "сообщил", "know", "knew", "understand", "understood", "explained", "said", "told", "reported", "remember", "remembered", "suggested"]

    private static func questionClauses(_ text: String) -> [[String]] {
        let normalized = text.lowercased().replacingOccurrences(of: "—", with: " ").replacingOccurrences(of: "–", with: " ")
        return normalized.components(separatedBy: CharacterSet(charactersIn: ".!;\n")).map {
            $0.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        }
    }
    private static func trimFillers(_ input: [String]) -> [String] {
        var words = input
        var removed = 0
        while !words.isEmpty, removed < 6 {
            if words.starts(with: ["то", "есть"]) { words.removeFirst(2); removed += 2 }
            else if let word = words.first, fillers.contains(word) { words.removeFirst(); removed += 1 }
            else { break }
        }
        return words
    }
    private static func isQuestionClause(_ input: [String]) -> Bool {
        var words = trimFillers(input)
        guard let first = words.first, !isStatement(words) else { return false }
        if words.count >= 3, words[0] == "если", ["можешь", "можете"].contains(words[1]) {
            words = trimFillers(Array(words.dropFirst(2)))
            return words.first.map { imperatives.contains($0) } ?? false
        }
        if imperatives.contains(first) || interrogatives.contains(first) { return true }
        if words.count > 1, prepositions.contains(first), interrogatives.contains(words[1]) { return true }
        if ["можешь", "можете"].contains(first) { return true }
        if words.starts(with: ["можно", "ли"]) || words.starts(with: ["не", "могли", "бы", "вы"]) { return true }
        if words.count > 1, ["can", "could", "would", "will", "do", "did", "are", "have"].contains(first), words[1] == "you" { return true }
        if ["ты", "вы", "you"].contains(first) {
            if words.count > 1, ["можешь", "можете", "can", "could", "would"].contains(words[1]) { return true }
            if words.prefix(12).contains("или") || words.prefix(12).contains("or") { return true }
        }
        for index in words.indices.dropFirst() where interrogatives.contains(words[index]) {
            let prefix = words[..<index]
            guard !prefix.contains(where: { reported.contains($0) }) else { continue }
            guard !narrativeSubjects.contains(first) || hasRequestIntent(prefix) else { continue }
            let question = Array(words[index...])
            guard !isStatement(question) else { continue }
            if question.dropFirst().prefix(5).contains(where: { addresses.contains($0) }) { return true }
        }
        return false
    }
    private static func hasRequestIntent(_ words: ArraySlice<String>) -> Bool {
        guard !words.contains("не") else { return false }
        return words.contains(where: { ["хочу", "хотим", "хотел", "хотела", "хотели"].contains($0) })
            && words.contains(where: { ["спросить", "уточнить"].contains($0) })
    }
    private static func isStatement(_ words: [String]) -> Bool {
        let idioms = [["как", "правило"], ["как", "известно"], ["как", "раз"], ["как", "оказалось"], ["как", "выяснилось"], ["for", "what", "it", "s", "worth"]]
        if idioms.contains(where: { words.starts(with: $0) }) { return true }
        guard words.count >= 3 else { return false }
        if ["what", "how"].contains(words[0]), ["i", "we"].contains(words[1]) { return true }
        if ["что", "как"].contains(words[0]), ["я", "мы"].contains(words[1]) {
            let verb = words[2]
            return verb.count > 3 && !["мог", "могла", "могли"].contains(verb) && ["л", "ла", "ли"].contains(where: { verb.hasSuffix($0) })
        }
        return false
    }
}
