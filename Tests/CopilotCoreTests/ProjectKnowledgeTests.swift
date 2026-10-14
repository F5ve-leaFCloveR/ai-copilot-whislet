import Foundation
import Testing
@testable import CopilotCore

struct ProjectKnowledgeTests {
    private let knowledge = ProjectKnowledge(
        title: "Example meeting service",
        snapshotDate: "2024-04-12",
        sourcePaths: ["fixtures/guide.html", "fixtures/index.html"],
        overview: "Вымышленный учебный проект. Срез, не live проверка.",
        sections: [
            .init(id: "identity", title: "Авторизация и identity", text: "Текущий вход участника — OIDC. LDAP встречается только в старой целевой архитектуре; его наличие сейчас не подтверждено.", source: "guide.html#identity"),
            .init(id: "storage", title: "Хранение состояния", text: "PostgreSQL — основная история встреч. SQLite хранит offline cache на клиенте. SQLite не заменяет PostgreSQL backend.", source: "guide.html#storage"),
            .init(id: "calendar", title: "Calendar connector availability", text: "Calendar code существует. Dev config содержит Calendar. Prod config его не содержит. Running process не доказывает успешный E2E.", source: "index.html#calendar"),
            .init(id: "queue", title: "Queue delivery", text: "Queue доставляет уведомления. Повтор notification возможен после publish confirm до mark_sent; клиенту нужна дедупликация.", source: "index.html#queue")
        ]
    )

    @Test func currentIdentityIsRetrievedWithoutReplacingItWithHistoricalArchitecture() {
        let selection = knowledge.select(question: "У нас сейчас LDAP или OIDC?")
        #expect(selection.sectionIDs.first == "identity")
        #expect(selection.text.contains("Текущий вход участника — OIDC"))
        #expect(selection.text.contains("старой целевой архитектуре"))
        #expect(selection.text.contains("2024-04-12"))
        #expect(selection.text.contains("fixtures/guide.html"))
    }

    @Test func storageQueryKeepsThePrimaryHistoryAndMirrorDistinction() {
        let selection = knowledge.select(question: "Где хранится история: SQLite или Postgres?")
        #expect(selection.sectionIDs.first == "storage")
        #expect(selection.text.contains("основная история"))
        #expect(selection.text.contains("не заменяет PostgreSQL"))
    }

    @Test func availabilityQueryRetainsCodeConfigRunningAndE2EDistinctions() {
        let selection = knowledge.select(question: "Calendar уже работает на prod? Есть успешный E2E?")
        #expect(selection.sectionIDs.first == "calendar")
        #expect(selection.text.contains("Prod config его не содержит"))
        #expect(selection.text.contains("Running process не доказывает успешный E2E"))
    }

    @Test func unrelatedQuestionDoesNotReusePreviousProjectTopic() {
        let selection = knowledge.select(question: "Какая завтра погода в Лондоне?", recentContext: "Обсуждали OIDC, SQLite и Calendar")
        #expect(!selection.hasRelevantSections)
        #expect(selection.sectionIDs.isEmpty)
        #expect(selection.text.contains("Срез, не live проверка"))
    }

    @Test func shortFollowupUsesRecentUtteranceContext() {
        let selection = knowledge.select(question: "А почему?", recentContext: "Queue может прислать повторный notification")
        #expect(selection.sectionIDs.first == "queue")
        #expect(selection.text.contains("publish confirm"))
    }

    @Test func strictUTF8BudgetKeepsValidUnicodeAndRelevantTailOfLargeSection() {
        let corpus = ProjectKnowledge(title: "Пример", snapshotDate: "2024-04-12", sourcePaths: ["guide.html"], overview: "Вымышленный срез", sections: [
            .init(id: "long", title: "Deployment", text: String(repeating: "😀 Общая строка без искомого термина.\n", count: 500) + "\nКлючевой факт: migrations не доставляются sync.\n", source: "guide.html#deployment")
        ])
        let selection = corpus.select(question: "Что с migrations?", maxUTF8Bytes: 900)
        #expect(selection.utf8Bytes <= 900)
        #expect(selection.utf8Bytes == selection.text.utf8.count)
        #expect(selection.text.contains("migrations не доставляются sync"))
        #expect(selection.hasRelevantSections)
        #expect(!selection.text.contains("�"))
    }

    @Test func corpusRoundTripPreservesUnselectedSections() throws {
        let data = try JSONEncoder().encode(knowledge)
        let decoded = try JSONDecoder().decode(ProjectKnowledge.self, from: data)
        #expect(decoded.sections.count == 4)
        #expect(decoded.sections.last?.text == knowledge.sections.last?.text)
        #expect(decoded.select(question: "OIDC").sectionIDs.first == "identity")
    }

    @Test func explanatoryFactsOutrankFilenameAndInventoryMatches() {
        var sections = (0..<12).map { index in
            ProjectKnowledgeSection(id: "file-\(index)", title: "Atlas / fileInventory / sqlite-postgres-\(index).py", text: "path: sqlite/postgres.py\nbytes: 900\nsha256: example", source: "index.html#inventory")
        }
        sections.append(.init(id: "primary", title: "Где хранится состояние", text: "PostgreSQL — основная история. SQLite — offline cache, не backend.", source: "guide.html#storage"))
        let corpus = ProjectKnowledge(title: "Example meeting service", snapshotDate: "2024-04-12", sourcePaths: ["guide.html", "index.html"], overview: "Вымышленный срез", sections: sections)
        let selection = corpus.select(question: "SQLite или Postgres?")
        #expect(selection.sectionIDs.first == "primary")
        #expect(selection.text.contains("PostgreSQL — основная история"))
    }
}
