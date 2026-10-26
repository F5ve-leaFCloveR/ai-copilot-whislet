import AppKit
import Combine
import CopilotCore

enum UIPhase: String, Codable { case stopped, warming, listening, generating, paused, failed, budgetLimit }
enum UIHintStatus: String { case waiting, streaming, ready, cancelled, incomplete, failed }

struct UIDisplayOption: Identifiable, Codable, Equatable {
    var id: UInt32
    var name: String
}

struct UIWindowLayout: Codable, Equatable {
    var toolbarX: Double
    var toolbarY: Double
    var answerOffsetX: Double
    var answerOffsetY: Double
    var answerWidth: Double
    var answerHeight: Double
}

struct UIHotkeyCommand: Identifiable, Sendable {
    let id: String
    let title: String
    let defaultLetter: String
}

enum UIHotkeys {
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) }
    static let commands = [
        UIHotkeyCommand(id: "manual", title: "Подсказка", defaultLetter: "H"),
        UIHotkeyCommand(id: "screenshot", title: "Скриншот", defaultLetter: "S"),
        UIHotkeyCommand(id: "hide", title: "Скрыть все окна", defaultLetter: "X"),
        UIHotkeyCommand(id: "pause", title: "Пауза / продолжить", defaultLetter: "P"),
        UIHotkeyCommand(id: "previous", title: "Предыдущий ответ", defaultLetter: "B"),
        UIHotkeyCommand(id: "latest", title: "Последний ответ", defaultLetter: "N"),
        UIHotkeyCommand(id: "translate", title: "Перевести вопрос", defaultLetter: "T")
    ]
}

struct UISettings: Codable, Equatable {
    var profileName = "AI Engineer"
    var profile = ""
    var vacancy = ""
    var profiles: [ConversationProfile]?
    var selectedProfileID: UUID?
    var fontSize = 15.0
    var opacity = 0.9
    var auto = true
    var model = "gpt-4.1-mini"
    var apiBaseURL: String?
    var strictJSONSchema: Bool?
    var language = "Russian"
    var displayID: UInt32 = 0
    var service = "Zoom"
    var shareMode = "Весь экран"
    var screenshotMode = "Экран"
    var hotkeysEnabled = true
    var hotkeyLetters: [String: String]?
    var layout: UIWindowLayout?

    mutating func adaptDefaultModel(to connection: APIConnection) {
        guard connection.dialect != .standard || connection.baseURL.host == "api.openai.com" else { return }
        let defaults = [APIConnection.legacy.defaultModel, APIConnection.openRouter.defaultModel, APIConnection.openAI.defaultModel]
        if defaults.contains(model) { model = connection.defaultModel }
    }

    func hotkeyLetter(_ command: String) -> String {
        hotkeyLetters?[command]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? UIHotkeys.commands.first(where: { $0.id == command })?.defaultLetter ?? "?"
    }
    func hotkeyShortcut(_ command: String) -> String { "⌃⌥" + hotkeyLetter(command) }
}

struct UITranscriptItem: Identifiable, Equatable {
    var id = UUID()
    var speaker: String
    var text: String
    var time: String = ""
}

struct UIHistoryItem: Identifiable, Equatable {
    var id: UUID
    var question: String
    var text: String
    var status: UIHintStatus
    var model: String
    var hasScreenshot = false
}

struct UIQuestionTranslation: Equatable {
    private(set) var question: Utterance?
    private(set) var requestID: UUID?
    private(set) var text = ""
    private(set) var status: UIHintStatus = .waiting
    private(set) var error = ""

    mutating func begin(_ question: Utterance) -> UUID {
        let id = UUID()
        self = Self(question: question, requestID: id, status: .streaming)
        return id
    }

    func matches(_ question: Utterance) -> Bool {
        self.question?.id == question.id && self.question?.text == question.text
    }

    mutating func updateQuestion(_ question: Utterance) {
        guard self.question?.id == question.id else { return }
        self.question = question
    }

    mutating func apply(_ event: GenerationEvent) {
        guard event.id == requestID, status == .streaming else { return }
        switch event {
        case .text(_, let delta): text += delta
        case .done(_, _, let reason): status = reason == "stop" && !text.isEmpty ? .ready : .incomplete
        case .failed(_, let message): status = .failed; error = message
        default: break
        }
    }

    mutating func clear() { self = Self() }
    mutating func fail(_ message: String) { self = Self(status: .failed, error: message) }
}

struct UIPresentation: Equatable {
    var phase: UIPhase = .stopped
    var question = ""
    var text = ""
    var followups: [String] = []
    var hintStatus: UIHintStatus = .waiting
    var translation = UIQuestionTranslation()
    var selectedCardID: UUID?
    var answerRevealRevision = 0
    var selectedIndex = 0
    var pendingCount = 0
    var transcript: [UITranscriptItem] = []
    var history: [UIHistoryItem] = []
    var systemLevel = 0.0
    var microphoneLevel = 0.0
    var hasScreenshot = false
    var screenshotLabel = ""
    var isReadingHistory = false
    var error = ""
    var budgetText = "0 ₽ / 50 ₽"
    var keyStatus = "Ключ не настроен"
    var apiEndpoint = APIConnection.openAI.baseURL.absoluteString
    var apiDialect: APIConnection.Dialect = .standard
    var asrStatus = "Распознавание не запущено"
    var audioStatus = "Звук не подключён"
    var privacyStatus = "Проверка трансляции"
    var privacyConfirmed = false
    var localCapturePassed = false
    var displays: [UIDisplayOption] = []
    var hotkeyError = ""
    var isDemo = false
}

enum UIAction {
    case startStop, manual(String?), screenshot, pause, hide, previous, latest
    case translateQuestion, dismissTranslation
    case settings, context, history, saveSettings(UISettings), recover
    case setAuto(Bool), setModel(String), selectHistory(UUID), pinHistory
    case checkPrivacy, confirmPrivacy, saveKey(String), windowLayout(UIWindowLayout), moreDetail, quit, cancelHint
}

@MainActor
final class UIModel: ObservableObject {
    @Published var settings = UISettings()
    @Published private(set) var presentation = UIPresentation()
    var onAction: ((UIAction) -> Void)?
    var onContentRendered: ((UUID, Double) -> Void)?
    var onProfileChanged: ((UUID?, UUID) -> Void)?

    func apply(_ value: UIPresentation) { presentation = value }
    func refresh() { objectWillChange.send() }
    func send(_ action: UIAction) { onAction?(action) }
    func saveSettings() { settings.syncActiveProfile(); send(.saveSettings(settings)) }
    func selectProfile(_ id: UUID) {
        let previous = settings.activeProfile.id
        guard settings.selectProfile(id) else { return }
        if previous != id { onProfileChanged?(previous, id) }
        saveSettings()
    }
    func addProfile(kind: ConversationProfileKind, duplicateCurrent: Bool = false) {
        let previous = settings.activeProfile.id
        let id = settings.addProfile(kind: kind, duplicateCurrent: duplicateCurrent)
        onProfileChanged?(previous, id)
        saveSettings()
    }
    func deleteActiveProfile() {
        let previous = settings.activeProfile.id
        guard settings.deleteActiveProfile() else { return }
        onProfileChanged?(previous, settings.activeProfile.id)
        saveSettings()
    }
    var isRunning: Bool { presentation.phase != .stopped }
    var isGenerating: Bool { presentation.hintStatus == .streaming || presentation.phase == .generating }

    var modelChoices: [String] {
        let suggestions: [String]
        switch presentation.apiDialect {
        case .legacyGateway: suggestions = ["gemini-3.8-flash", "gemini-3.5-flash-lite", "claude-haiku-5.5", "gpt-4.1-mini"]
        case .openRouter: suggestions = ["openai/gpt-4.1-mini", "openai/gpt-4.1", "openai/gpt-4o-mini"]
        case .standard: suggestions = URL(string: presentation.apiEndpoint)?.host?.lowercased() == "api.openai.com" ? ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"] : []
        }
        return [settings.model] + suggestions.filter { $0 != settings.model }
    }

    static func modelName(_ value: String) -> String {
        switch value {
        case "claude-haiku-5.5": "Haiku 5.5"
        case "gemini-3.5-flash-lite": "Gemini Flash Lite"
        case "gemini-3.8-flash": "Gemini 3.8 Flash"
        case "gpt-4.1-mini", "openai/gpt-4.1-mini": "GPT-4.1 mini"
        case "gpt-4.1", "openai/gpt-4.1": "GPT-4.1"
        case "gpt-4o-mini", "openai/gpt-4o-mini": "GPT-4o mini"
        default: value
        }
    }
}
