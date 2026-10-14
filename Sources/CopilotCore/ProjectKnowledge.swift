import Foundation

public struct ProjectKnowledgeSection: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var text: String
    public var source: String

    public init(id: String, title: String, text: String, source: String) {
        self.id = id
        self.title = title
        self.text = text
        self.source = source
    }
}

public struct ProjectKnowledgeSelection: Sendable, Equatable {
    public let text: String
    public let sectionIDs: [String]
    public var hasRelevantSections: Bool { !sectionIDs.isEmpty }
    public var utf8Bytes: Int { text.utf8.count }

    public init(text: String, sectionIDs: [String]) {
        self.text = text
        self.sectionIDs = sectionIDs
    }
}

public struct ProjectKnowledge: Codable, Sendable, Equatable {
    public var title: String
    public var snapshotDate: String
    public var sourcePaths: [String]
    public var overview: String
    public var sections: [ProjectKnowledgeSection] {
        didSet { searchIndex = Self.makeIndex(sections) }
    }
    private var searchIndex: [IndexedSection]

    private struct IndexedSection: Sendable {
        let index: Int
        let heading: Set<String>
        let body: Set<String>
    }

    private enum CodingKeys: String, CodingKey {
        case title, snapshotDate, sourcePaths, overview, sections
    }

    public init(title: String, snapshotDate: String, sourcePaths: [String], overview: String, sections: [ProjectKnowledgeSection]) {
        self.title = title
        self.snapshotDate = snapshotDate
        self.sourcePaths = sourcePaths
        self.overview = overview
        self.sections = sections
        self.searchIndex = Self.makeIndex(sections)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try values.decode(String.self, forKey: .title),
            snapshotDate: try values.decode(String.self, forKey: .snapshotDate),
            sourcePaths: try values.decode([String].self, forKey: .sourcePaths),
            overview: try values.decode(String.self, forKey: .overview),
            sections: try values.decode([ProjectKnowledgeSection].self, forKey: .sections)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(snapshotDate, forKey: .snapshotDate)
        try values.encode(sourcePaths, forKey: .sourcePaths)
        try values.encode(overview, forKey: .overview)
        try values.encode(sections, forKey: .sections)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.snapshotDate == rhs.snapshotDate && lhs.sourcePaths == rhs.sourcePaths && lhs.overview == rhs.overview && lhs.sections == rhs.sections
    }

    private static func makeIndex(_ sections: [ProjectKnowledgeSection]) -> [IndexedSection] {
        sections.enumerated().map { index, section in
            IndexedSection(index: index, heading: Self.terms(section.title), body: Self.terms(section.text))
        }
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func select(question: String, recentContext: String = "", maxUTF8Bytes: Int = 24_000) -> ProjectKnowledgeSelection {
        let budget = max(0, maxUTF8Bytes)
        let questionTerms = Self.terms(question)
        let contextTerms = Self.terms(recentContext)
        let query = questionTerms.isEmpty ? contextTerms : questionTerms
        let indexed = searchIndex
        let frequencies = query.reduce(into: [String: Int]()) { result, term in
            result[term] = indexed.filter { $0.heading.contains(term) || $0.body.contains(term) }.count
        }
        let ranked = indexed.compactMap { item -> (index: Int, section: ProjectKnowledgeSection, score: Double)? in
            let matches = query.intersection(item.heading.union(item.body))
            guard !matches.isEmpty else { return nil }
            let lexicalScore = matches.reduce(0.0) { sum, term in
                let rarity = log(1.0 + Double(indexed.count) / Double(max(1, frequencies[term, default: 1])))
                return sum + rarity * (item.heading.contains(term) ? 5 : 1)
            } + Double(contextTerms.intersection(item.heading.union(item.body)).count) * 0.15
            let section = sections[item.index]
            let score = (lexicalScore + Double(matches.count * matches.count)) * Self.semanticWeight(section)
            return (item.index, section, score)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }

        let header = "Проект: \(title)\nСрез: \(snapshotDate); это документированный снимок, не live проверка\nИсточники: \(sourcePaths.joined(separator: "; "))\n\n\(overview)"
        var output = Self.prefix(header, utf8Bytes: min(budget, 6_000))
        var selected: [String] = []
        for item in ranked.prefix(10) {
            let label = "\n\n## \(item.section.title) [\(item.section.id)]\nИсточник: \(item.section.source)\n"
            let remaining = budget - output.utf8.count - label.utf8.count
            guard remaining >= 80 else { continue }
            let excerpt = Self.excerpt(item.section.text, query: query, utf8Bytes: min(remaining, 6_000))
            guard !excerpt.isEmpty else { continue }
            output += label + excerpt
            selected.append(item.section.id)
        }
        return ProjectKnowledgeSelection(text: output, sectionIDs: selected)
    }

    private static let stopWords: Set<String> = [
        "а", "и", "или", "но", "в", "во", "на", "по", "с", "со", "к", "у", "за", "из", "для", "от", "не", "нет", "да",
        "я", "мы", "ты", "вы", "он", "она", "они", "это", "того", "этого", "этот", "наша", "наш", "наши", "нас", "нам",
        "как", "какой", "какая", "какие", "что", "где", "почему", "зачем", "когда", "можно", "может", "нужно", "надо",
        "есть", "быть", "был", "будет", "уже", "сейчас", "теперь", "еще", "так", "тоже", "просто", "вопрос", "проект",
        "the", "a", "an", "is", "are", "was", "be", "to", "for", "of", "in", "on", "and", "or", "how", "what", "why", "our", "we"
    ]

    private static func terms(_ text: String) -> Set<String> {
        let aliases = [
            "postgresql": "postgres", "постгрес": "postgres", "постгресе": "postgres", "постгресql": "postgres",
            "склайт": "sqlite", "э2э": "e2e", "телеграм": "telegram", "телеграмм": "telegram",
            "авторизация": "identity", "аутентификация": "identity", "логин": "identity", "вход": "identity",
            "authentication": "identity", "authorization": "identity"
        ]
        let normalized = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { word in
            guard word.count >= 2, !stopWords.contains(word), !word.allSatisfy(\.isNumber) else { return nil }
            if let alias = aliases[word] { return alias }
            guard word.range(of: "[а-я]", options: .regularExpression) != nil, word.count >= 5 else { return word }
            for ending in ["изация", "ениями", "аниями", "ением", "ания", "ение", "ится", "ются", "ами", "ями", "ого", "ему", "ыми", "ость", "ать", "ять", "ить", "ий", "ый", "ой", "ая", "ое", "ые", "ов", "ам", "ах", "ях", "ию", "ия", "ие", "ы", "и", "а", "я", "е", "у"] {
                if word.hasSuffix(ending), word.count - ending.count >= 4 { return String(word.dropLast(ending.count)) }
            }
            return word
        })
    }

    private static func semanticWeight(_ section: ProjectKnowledgeSection) -> Double {
        let title = section.title.lowercased()
        if ["/ fileinventory /", "/ sources /", "/ tests /", "/ manifest evidence /"].contains(where: title.contains) { return 0.06 }
        if ["/ server / paths /", "/ server / artifact_candidates /", "/ server / services /", "/ server / timers /"].contains(where: title.contains) { return 0.12 }
        if title.contains("/ server / containers /") { return 0.35 }
        if title.contains("/ server / databases /") { return 0.5 }
        if title.hasPrefix("live inventory") { return 0.55 }
        if title.hasPrefix("atlas / ") { return 1.2 }
        return 1.7
    }

    private static func prefix(_ text: String, utf8Bytes: Int) -> String {
        guard utf8Bytes > 0 else { return "" }
        guard text.utf8.count > utf8Bytes else { return text }
        var count = 0
        var result = ""
        for character in text {
            let width = String(character).utf8.count
            guard count + width <= utf8Bytes else { break }
            result.append(character)
            count += width
        }
        return result
    }

    private static func excerpt(_ text: String, query: Set<String>, utf8Bytes: Int) -> String {
        guard text.utf8.count > utf8Bytes else { return text }
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var candidates: [(index: Int, text: String, matches: Int)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let count = Self.terms(paragraph).intersection(query).count
            if count > 0 { candidates.append((index, paragraph, count)) }
        }
        let ranked = candidates.sorted { lhs, rhs in
            lhs.matches == rhs.matches ? lhs.index < rhs.index : lhs.matches > rhs.matches
        }
        var selected: [Int: String] = [:]
        var remaining = utf8Bytes
        for paragraph in ranked {
            guard remaining > 0 else { break }
            let clipped = Self.prefix(paragraph.text, utf8Bytes: remaining)
            selected[paragraph.index] = clipped
            remaining -= clipped.utf8.count + 1
        }
        guard !selected.isEmpty else { return Self.prefix(text, utf8Bytes: utf8Bytes) }
        return Self.prefix(selected.keys.sorted().compactMap { selected[$0] }.joined(separator: "\n"), utf8Bytes: utf8Bytes)
    }
}
