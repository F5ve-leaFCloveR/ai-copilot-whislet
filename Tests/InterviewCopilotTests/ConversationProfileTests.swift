import Foundation
import Testing
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct ConversationProfileTests {
    @Test func recruiterProfilePersistsItsModeWithoutProjectKnowledge() throws {
        var settings = UISettings()
        settings.migrateProfiles()
        let interviewID = settings.activeProfile.id
        let recruiterID = settings.addProfile(kind: .recruiterInterview)
        settings.profileName = "Example · Experience"
        settings.profile = "Fictional candidate: I practise public speaking."
        settings.vacancy = "Nontechnical interview in English"
        var saved = SavedSettings(); saved.ui = settings
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(saved))
        #expect(restored.ui.selectedProfileID == recruiterID)
        #expect(restored.ui.activeProfile.kind.conversationMode == .recruiterInterview)
        #expect(restored.ui.activeProfile.knowledgeFile == nil)
        #expect(restored.ui.profiles?.contains(where: { $0.id == interviewID }) == true)
        #expect(restored.ui.activeProfile.context == "Fictional candidate: I practise public speaking.")
        #expect(ConversationProfileKind.interview.conversationMode == .interview)
        #expect(ConversationProfileKind.work.conversationMode == .work)
    }

    @Test func legacySettingsGainAnInterviewProfileAndKeepGlobalSettings() throws {
        var original = SavedSettings()
        original.ui.profileName = "Мой профиль"
        original.ui.profile = "Я разработал API; метрики не указаны."
        original.ui.vacancy = "Backend Engineer"
        original.ui.fontSize = 13
        original.ui.auto = false
        original.ui.hotkeyLetters = ["manual": "A"]
        original.ui.layout = UIWindowLayout(toolbarX: 15, toolbarY: 25, answerOffsetX: 0, answerOffsetY: -60, answerWidth: 480, answerHeight: 500)
        original.pythonPath = "/test/python"
        original.confirmations = [SavedPrivacyConfirmation(service: "Zoom", mode: "Весь экран", displayID: 3, version: "1", checkedAt: Date(timeIntervalSince1970: 123))]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var ui = try #require(object["ui"] as? [String: Any])
        ui.removeValue(forKey: "profiles")
        ui.removeValue(forKey: "selectedProfileID")
        object["ui"] = ui
        let migrated = try JSONDecoder().decode(SavedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        let encodedUI = try #require(encoded["ui"] as? [String: Any])
        let profiles = encodedUI["profiles"] as? [[String: Any]]
        #expect(profiles?.count == 1)
        #expect(profiles?.first?["name"] as? String == "Мой профиль")
        #expect(profiles?.first?["kind"] as? String == "interview")
        #expect(profiles?.first?["context"] as? String == "Я разработал API; метрики не указаны.")
        #expect(profiles?.first?["vacancy"] as? String == "Backend Engineer")
        #expect(migrated.ui.profile == original.ui.profile)
        #expect(migrated.ui.fontSize == 13)
        #expect(!migrated.ui.auto)
        #expect(migrated.ui.hotkeyLetters == ["manual": "A"])
        #expect(migrated.ui.layout == original.ui.layout)
        #expect(migrated.pythonPath == "/test/python")
        #expect(migrated.confirmations.first?.checkedAt == Date(timeIntervalSince1970: 123))
    }

    @Test func switchingKeepsDraftsIsolatedAndPersistsTheSelectedWorkProfile() throws {
        var settings = UISettings()
        settings.profileName = "Собеседования"
        settings.profile = "Реальный опыт Python"
        settings.vacancy = "AI Engineer"
        settings.fontSize = 13
        settings.migrateProfiles()
        let interviewID = settings.activeProfile.id
        let workID = settings.addProfile(kind: .work)
        settings.profileName = "Example project"
        settings.profile = "Контекст проекта"
        settings.vacancy = "Обсудить rollout"
        settings.profiles?[1].knowledgeFile = "/private/project.json"
        let switchedToInterview = settings.selectProfile(interviewID)
        #expect(switchedToInterview)
        #expect(settings.profile == "Реальный опыт Python")
        #expect(settings.vacancy == "AI Engineer")
        settings.profile = "Реальный опыт Python и FastAPI"
        let switchedToWork = settings.selectProfile(workID)
        #expect(switchedToWork)
        #expect(settings.profileName == "Example project")
        #expect(settings.profile == "Контекст проекта")
        #expect(settings.vacancy == "Обсудить rollout")
        #expect(settings.activeProfile.kind == .work)
        #expect(settings.activeProfile.knowledgeFile == "/private/project.json")
        var saved = SavedSettings(); saved.ui = settings
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(saved))
        #expect(restored.ui.selectedProfileID == workID)
        #expect(restored.ui.activeProfile.knowledgeFile == "/private/project.json")
        #expect(restored.ui.profiles?.first(where: { $0.id == interviewID })?.context == "Реальный опыт Python и FastAPI")
        #expect(restored.ui.fontSize == 13)
    }

    @Test func deletionAndDuplicationPreserveAnotherProfileAndRejectUnknownSelection() {
        var settings = UISettings()
        settings.profileName = "Собеседования"
        settings.profile = "Мои факты"
        settings.migrateProfiles()
        let interviewID = settings.activeProfile.id
        let duplicateID = settings.addProfile(kind: .work, duplicateCurrent: true)
        #expect(duplicateID != interviewID)
        #expect(settings.activeProfile.kind == .interview)
        #expect(settings.activeProfile.context == "Мои факты")
        settings.profile = "Только в копии"
        let unknownWasSelected = settings.selectProfile(UUID())
        #expect(!unknownWasSelected)
        #expect(settings.profile == "Только в копии")
        let duplicateWasDeleted = settings.deleteActiveProfile()
        #expect(duplicateWasDeleted)
        #expect(settings.activeProfile.id == interviewID)
        #expect(settings.profile == "Мои факты")
        let lastWasDeleted = settings.deleteActiveProfile()
        #expect(!lastWasDeleted)
    }

    @Test func profileChangeCallbackRunsBeforePersistenceAndOnlyForAChangedSelection() {
        let model = UIModel()
        model.settings.migrateProfiles()
        let originalID = model.settings.activeProfile.id
        var callbackIDs: [UUID] = []
        var eventOrder: [String] = []
        model.onProfileChanged = { previous, current in
            #expect(previous == originalID)
            #expect(model.settings.activeProfile.id == current)
            callbackIDs.append(current); eventOrder.append("change")
        }
        model.onAction = { action in
            if case .saveSettings(let settings) = action {
                #expect(settings.profiles?.first(where: { $0.id == settings.selectedProfileID })?.context == settings.profile)
                eventOrder.append("save")
            }
        }
        model.addProfile(kind: .work)
        let workID = model.settings.activeProfile.id
        model.selectProfile(workID)
        #expect(callbackIDs == [workID])
        #expect(eventOrder == ["change", "save", "save"])
    }

    @Test func invalidSavedSelectionFallsBackWithoutDiscardingRecords() throws {
        var saved = SavedSettings()
        saved.ui.migrateProfiles()
        let interviewID = saved.ui.activeProfile.id
        _ = saved.ui.addProfile(kind: .work)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var ui = try #require(object["ui"] as? [String: Any])
        ui["selectedProfileID"] = UUID().uuidString
        object["ui"] = ui
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.ui.selectedProfileID == interviewID)
        #expect(restored.ui.profiles?.count == 2)
    }
}
