import Foundation
import Testing
@testable import CopilotCore

@Suite struct APIConnectionTests {
    @Test func knownKeysSelectEndpointsAndModels() throws {
        let router = try APIConnection.resolve(apiKey: "sk-or-test")
        #expect(router == .openRouter)
        #expect(router.defaultModel == "openai/gpt-4.1-mini")
        let legacy = try APIConnection.resolve(apiKey: "sk-aitunnel-test")
        #expect(legacy == .legacy)
        #expect(legacy.supportsBalance)
        #expect(legacy.defaultModel == "gemini-3.8-flash")
        let standard = try APIConnection.resolve(apiKey: "sk-test")
        #expect(standard == .openAI)
        #expect(standard.defaultModel == "gpt-4.1-mini")
        #expect(!standard.supportsBalance)
    }

    @Test func explicitEndpointWinsOverKeyPrefix() throws {
        let custom = try APIConnection.resolve(apiKey: "sk-or-test", explicitBaseURL: "https://gateway.example/v1/", strictSchema: false)
        #expect(custom.baseURL.absoluteString == "https://gateway.example/v1")
        #expect(custom.dialect == .standard)
        #expect(!custom.strictSchema)
        #expect(try APIConnection.resolve(apiKey: "sk-aitunnel-test", explicitBaseURL: "https://openrouter.ai/api/v1").dialect == .openRouter)
        #expect(try APIConnection(baseURL: "https://api.aitunnel.ru.example/v1").dialect == .standard)
    }

    @Test func endpointsRejectCredentialsAndInsecureRemoteURLs() throws {
        for value in ["", "gateway.example/v1", "http://gateway.example/v1", "https://user:secret@gateway.example/v1", "https://gateway.example/v1?token=secret", "https://gateway.example/v1#fragment", "file:///tmp/v1"] {
            #expect(throws: APIConnectionError.self) { try APIConnection(baseURL: value) }
        }
        for value in ["http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"] {
            #expect(try APIConnection(baseURL: value).dialect == .standard)
        }
    }

    @Test func authorizationStaysOnConfiguredOrigin() throws {
        let connection = try APIConnection(baseURL: "https://gateway.example/v1")
        #expect(connection.accepts(URL(string: "https://gateway.example/v1/chat/completions")!))
        #expect(connection.accepts(URL(string: "https://gateway.example:443/redirect")!))
        for target in ["https://other.example/v1", "https://gateway.example:444/v1", "http://gateway.example/v1", "https://gateway.example.evil/v1"] {
            #expect(!connection.accepts(URL(string: target)!))
        }
    }

    @Test func payloadDialectAndSchemaAreIndependentOfAnswerRules() throws {
        let question = Utterance(source: .system, text: "What is an actor?", endedAt: 1, isFinal: true)
        func payload(_ connection: APIConnection) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: PromptBuilder().build(HintRequest(question: question, connection: connection))) as? [String: Any])
        }
        let legacy = try payload(.legacy)
        #expect(legacy["provider"] != nil)
        #expect(legacy["reasoning"] != nil)
        #expect(legacy["max_tokens"] as? Int == 2048)
        let openAI = try payload(.openAI)
        #expect(openAI["provider"] == nil)
        #expect(openAI["reasoning"] == nil)
        #expect(openAI["max_tokens"] == nil)
        #expect(openAI["max_completion_tokens"] as? Int == 2048)
        let router = try payload(.openRouter)
        #expect(router["provider"] == nil)
        #expect(router["reasoning"] == nil)
        #expect(router["max_tokens"] as? Int == 2048)
        let relaxed = try payload(APIConnection(baseURL: "https://gateway.example/v1", strictSchema: false))
        #expect(relaxed["response_format"] == nil)
        #expect(NSArray(array: try #require(legacy["messages"] as? [Any])) == NSArray(array: try #require(relaxed["messages"] as? [Any])))
    }
}
