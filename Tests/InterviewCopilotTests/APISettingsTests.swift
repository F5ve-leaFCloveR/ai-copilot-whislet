import Foundation
import Testing
import CopilotCore
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct APISettingsTests {
    @Test func freshSettingsUseAStandardModel() {
        #expect(UISettings().model == "gpt-4.1-mini")
    }

    @Test func legacySettingsKeepTheModelProfilesAndLayout() throws {
        var saved = SavedSettings()
        saved.ui.model = "gemini-3.8-flash"
        saved.ui.profileName = "Example profile"
        saved.ui.profile = "Example context"
        saved.ui.migrateProfiles()
        saved.ui.layout = UIWindowLayout(toolbarX: 10, toolbarY: 20, answerOffsetX: 0, answerOffsetY: -60, answerWidth: 480, answerHeight: 500)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var ui = try #require(object["ui"] as? [String: Any])
        ui.removeValue(forKey: "apiBaseURL")
        ui.removeValue(forKey: "strictJSONSchema")
        object["ui"] = ui
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.ui.model == saved.ui.model)
        #expect(restored.ui.profiles == saved.ui.profiles)
        #expect(restored.ui.layout == saved.ui.layout)
        #expect(restored.ui.selectedProfileID == saved.ui.selectedProfileID)
    }

    @Test func explicitEndpointAndSchemaChoiceSurviveRoundTrip() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedSettings())) as? [String: Any])
        var ui = try #require(object["ui"] as? [String: Any])
        ui["apiBaseURL"] = "https://example.com/v1"
        ui["strictJSONSchema"] = false
        ui["model"] = "custom/model"
        object["ui"] = ui
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        let encodedUI = try #require(encoded["ui"] as? [String: Any])
        #expect(encodedUI["apiBaseURL"] as? String == "https://example.com/v1")
        #expect(encodedUI["strictJSONSchema"] as? Bool == false)
        #expect(encodedUI["model"] as? String == "custom/model")
    }

    @Test func switchingProvidersAdaptsOnlyTheirDefaultModels() {
        for connection in [APIConnection.openAI, .openRouter, .legacy] {
            for value in ["gpt-4.1-mini", "openai/gpt-4.1-mini", "gemini-3.8-flash"] {
                var settings = UISettings(); settings.model = value
                settings.adaptDefaultModel(to: connection)
                #expect(settings.model == connection.defaultModel)
            }
            var custom = UISettings(); custom.model = "custom/model"
            custom.adaptDefaultModel(to: connection)
            #expect(custom.model == "custom/model")
        }
    }

    @Test func modelChoicesFollowTheProviderAndKeepAnExactCustomID() throws {
        let model = UIModel(); model.settings.model = "custom/model"
        var presentation = UIPresentation()
        presentation.apiEndpoint = APIConnection.openRouter.baseURL.absoluteString
        presentation.apiDialect = .openRouter
        model.apply(presentation)
        #expect(model.modelChoices.first == "custom/model")
        #expect(model.modelChoices.dropFirst().allSatisfy { $0.hasPrefix("openai/") })
        presentation.apiEndpoint = APIConnection.legacy.baseURL.absoluteString
        presentation.apiDialect = .legacyGateway
        model.apply(presentation)
        #expect(model.modelChoices.contains("gemini-3.8-flash"))
        #expect(model.settings.model == "custom/model")
        presentation.apiEndpoint = "https://example.com/v1"
        presentation.apiDialect = .standard
        model.apply(presentation)
        #expect(model.modelChoices == ["custom/model"])
    }

    @Test func customEndpointKeepsExactIDsEvenWhenTheyMatchKnownDefaults() throws {
        let connection = try APIConnection(baseURL: "https://example.com/v1")
        for value in ["gpt-4.1-mini", "openai/gpt-4.1-mini", "gemini-3.8-flash"] {
            var settings = UISettings(); settings.model = value
            settings.adaptDefaultModel(to: connection)
            #expect(settings.model == value)
        }
    }
}
