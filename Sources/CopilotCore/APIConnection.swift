import Foundation

public enum APIConnectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, mismatchedConnection, unsupportedBalance
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Укажите HTTPS Base URL без логина, параметров и фрагмента"
        case .mismatchedConnection: "Настройки API изменились · повторите запрос"
        case .unsupportedBalance: "Этот провайдер не сообщает баланс через API"
        }
    }
}

public struct APIConnection: Equatable, Sendable {
    public enum Dialect: Equatable, Sendable { case legacyGateway, openRouter, standard }
    public let baseURL: URL
    public let strictSchema: Bool
    public var dialect: Dialect {
        switch baseURL.host?.lowercased() {
        case "api.aitunnel.ru": .legacyGateway
        case "openrouter.ai": .openRouter
        default: .standard
        }
    }
    public var supportsBalance: Bool { dialect == .legacyGateway }
    public var requiresCost: Bool { dialect == .legacyGateway }
    public var defaultModel: String {
        switch dialect {
        case .legacyGateway: "gemini-3.8-flash"
        case .openRouter: "openai/gpt-4.1-mini"
        case .standard: "gpt-4.1-mini"
        }
    }
    public static let legacy = try! APIConnection(baseURL: "https://api.aitunnel.ru/v1")
    public static let openRouter = try! APIConnection(baseURL: "https://openrouter.ai/api/v1")
    public static let openAI = try! APIConnection(baseURL: "https://api.openai.com/v1")

    public init(baseURL: String, strictSchema: Bool = true) throws {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw APIConnectionError.invalidURL }
        components.scheme = scheme; components.host = host
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw APIConnectionError.invalidURL }
        self.baseURL = url; self.strictSchema = strictSchema
    }

    public static func resolve(apiKey: String, explicitBaseURL: String? = nil, strictSchema: Bool = true) throws -> APIConnection {
        if let explicitBaseURL, !explicitBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try APIConnection(baseURL: explicitBaseURL, strictSchema: strictSchema)
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = key.hasPrefix("sk-or-") ? openRouter : key.hasPrefix("sk-aitunnel-") ? legacy : openAI
        return try APIConnection(baseURL: base.baseURL.absoluteString, strictSchema: strictSchema)
    }

    func accepts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        let defaultPort = baseURL.scheme == "https" ? 443 : 80
        return (url.port ?? defaultPort) == (baseURL.port ?? defaultPort)
    }
}
