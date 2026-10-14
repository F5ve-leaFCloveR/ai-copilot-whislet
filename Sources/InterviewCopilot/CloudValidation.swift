import AppKit
import CopilotCore

@MainActor
final class CloudValidation: NSObject, NSApplicationDelegate {
    private let key: String
    private let model = UIModel()
    private let registry = ProtectedWindowRegistry()
    private var ui: InterviewUI!
    private var firstPaint: [UUID: Double] = [:]
    private var budget = BudgetLedger(limitRub: 10)
    private var rows: [Row] = []
    private let projectContextStore = ProjectContextStore()
    private var task: Task<Void, Never>?
    private var exitCode: Int32 = 0
    private let evalGemini: Bool
    private let preset: ModelPreset
    private var hasVisionFixtures = false
    private var reportStem: String { (evalGemini ? "cloud-native-gemini" : "cloud-native") + (hasVisionFixtures ? "-vision" : "") }
    init(key: String) {
        let evalGemini = CommandLine.arguments.contains("--eval-gemini")
        var name = evalGemini ? "gemini-3.5-flash-lite" : "claude-haiku-5.5"
        if let index = CommandLine.arguments.firstIndex(of: "--eval-model"), CommandLine.arguments.indices.contains(index + 1), ["gemini-3.5-flash-lite", "gemini-3.8-flash", "claude-haiku-5.5", "gpt-4.1-mini"].contains(CommandLine.arguments[index + 1]) { name = CommandLine.arguments[index + 1] }
        self.key = key; self.evalGemini = evalGemini
        self.preset = ModelPreset(model: name, reasoningEffort: ModelPreset.defaultReasoningEffort(for: name), providerSort: "latency")
        super.init()
    }
    struct ConversationLine: Decodable { let source: AudioSource; let text: String }
    struct Fixture: Decodable {
        let id: String; let question: String; let long: Bool?; let imagePath: String?; let profile: String?
        let source: AudioSource?; let mode: ConversationMode?; let context: [ConversationLine]?
        let previousQuestion: String?; let previousAnswer: String?; let previousSource: AudioSource?
        let knowledgeFile: String?
    }
    struct Row: Codable {
        let id: String
        let requestID: UUID
        let firstContent: Double?
        let firstRender: Double?
        let total: Double
        let costRub: String?
        let status: String
        let text: String
        let followups: [String]
        let error: String?
        let source: AudioSource
        let mode: ConversationMode
        let conversationLines: Int
        let projectContextBytes: Int
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        registry.canShow = { _ in true }
        model.settings.displayID = CGMainDisplayID()
        model.settings.profile = "Учебный профиль: Python, FastAPI, RAG, PostgreSQL, Docker. Практический опыт Kubernetes и количественные результаты не указаны."
        model.settings.model = preset.model
        if let index = CommandLine.arguments.firstIndex(of: "--font-size"), CommandLine.arguments.indices.contains(index + 1), let size = Double(CommandLine.arguments[index + 1]), (12...24).contains(size) { model.settings.fontSize = size }
        model.onContentRendered = { [weak self] id, time in if self?.firstPaint[id] == nil { self?.firstPaint[id] = time } }
        ui = InterviewUI(model: model, registry: registry); ui.showToolbar(); ui.showAnswer()
        task = Task { await run() }
    }
    func applicationWillTerminate(_ notification: Notification) { task?.cancel(); if exitCode != 0 { exit(exitCode) } }
    private func run() async {
        let root = SettingsStore.projectDirectory
        do {
            try FileManager.default.createDirectory(at: SettingsStore.reportsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fixtureURL: URL
            if let index = CommandLine.arguments.firstIndex(of: "--cloud-fixtures"), CommandLine.arguments.indices.contains(index + 1) { fixtureURL = URL(fileURLWithPath: CommandLine.arguments[index + 1]) }
            else { fixtureURL = root.appendingPathComponent("eval/text-fixtures.json") }
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureURL))
            hasVisionFixtures = fixtures.contains { $0.imagePath != nil }
            try save(root: root)
            try saveRun(root: root, status: "running")
            let connection = try APIConnection.resolve(apiKey: key)
            let client = OpenAICompatibleClient(keyProvider: { [key] in key }, connection: connection)
            if connection.supportsBalance { let available = try await client.balance(); budget.observeKeyRemaining(available.availableRub) }
            for (index, fixture) in fixtures.enumerated() {
                guard index < 10 else { break }
                let jpeg = try fixture.imagePath.map { try loadJPEG(path: $0, root: root) }
                let requestID = UUID(); if connection.supportsBalance { try budget.authorize(id: requestID, reserveRub: 1) }
                let began = ProcessInfo.processInfo.systemUptime
                let question = Utterance(source: fixture.source ?? .system, text: fixture.question, endedAt: began, isFinal: true)
                let context = (fixture.context ?? []).enumerated().map { offset, line in Utterance(source: line.source, text: line.text, endedAt: began - Double((fixture.context?.count ?? 0) - offset), isFinal: true) }
                let previousHint: HintCard?
                if let previousQuestion = fixture.previousQuestion, let answer = fixture.previousAnswer {
                    previousHint = HintCard(id: UUID(), question: Utterance(source: fixture.previousSource ?? .system, text: previousQuestion, endedAt: began - 1, isFinal: true), text: answer, status: .ready)
                } else { previousHint = nil }
                let mode = fixture.mode ?? .interview
                let projectContext = mode == .work ? try await projectContextStore.context(path: fixture.knowledgeFile, question: question.text, recent: context, previousHint: previousHint) : ""
                var view = UIPresentation(); view.isDemo = true; view.phase = .generating
                view.question = fixture.question; view.selectedCardID = requestID; view.hintStatus = .streaming
                view.history = rows.map { UIHistoryItem(id: $0.requestID, question: "Проверочный вопрос", text: $0.text, status: .ready, model: preset.model) } + [UIHistoryItem(id: requestID, question: fixture.question, text: "", status: .streaming, model: preset.model)]
                view.selectedIndex = rows.count
                view.hasScreenshot = jpeg != nil; view.screenshotLabel = jpeg == nil ? "" : "Изображение fixture"
                model.apply(view)
                let long = fixture.long ?? false
                let requestPreset = ModelPreset(model: preset.model, reasoningEffort: preset.reasoningEffort, providerSort: preset.providerSort, maxTokens: 2048, structuredShort: !long)
                let request = HintRequest(id: requestID, question: question, context: context, profile: fixture.profile ?? model.settings.profile, preset: requestPreset, jpeg: jpeg, previousHint: previousHint, mode: mode, projectContext: projectContext, connection: connection)
                let stream = await client.generate(request)
                var firstContent: Double?, cost: Decimal?, status = "incomplete", failure: String?
                for try await event in stream {
                    switch event {
                    case .text(_, let delta):
                        if firstContent == nil { firstContent = ProcessInfo.processInfo.systemUptime }
                        view.text += delta; model.apply(view)
                    case .suggestions(_, let values): view.followups = values; model.apply(view)
                    case .usage(_, let value): cost = value; budget.settle(id: requestID, actualRub: value)
                    case .pricedUsage: break
                    case .done(_, let value, let reason):
                        if let value { cost = value; budget.settle(id: requestID, actualRub: value) }
                        status = reason == "stop" ? "ready" : "incomplete"
                        view.hintStatus = reason == "stop" ? .ready : .incomplete; view.phase = .listening; model.apply(view)
                    case .failed(_, let message): status = "failed"; failure = message; view.hintStatus = .failed; view.error = message; model.apply(view)
                    }
                }
                let completed = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(100))
                rows.append(Row(id: fixture.id, requestID: requestID, firstContent: firstContent.map { $0 - began }, firstRender: firstPaint[requestID].map { $0 - began }, total: completed - began, costRub: cost.map { NSDecimalNumber(decimal: $0).stringValue }, status: status, text: view.text, followups: view.followups, error: failure, source: question.source, mode: mode, conversationLines: context.count, projectContextBytes: projectContext.utf8.count))
                if let previewIndex = CommandLine.arguments.firstIndex(of: "--preview-fixture"), CommandLine.arguments.indices.contains(previewIndex + 1), fixture.id == CommandLine.arguments[previewIndex + 1] { let size = ui.answer.frame.size
                    ui.answer.setContentSize(NSSize(width: 680, height: 760))
                    try await Task.sleep(for: .milliseconds(100))
                    try ui.writePreview(to: SettingsStore.reportsDirectory.appendingPathComponent("answer-style-preview.png"))
                    ui.answer.setContentSize(size) }
                if let previewIndex = CommandLine.arguments.firstIndex(of: "--preview-fixtures"), CommandLine.arguments.indices.contains(previewIndex + 1), CommandLine.arguments[previewIndex + 1].split(separator: ",").contains(Substring(fixture.id)) {
                    let size = ui.answer.frame.size
                    for width in [480, 680] {
                        ui.answer.setContentSize(NSSize(width: width, height: 760))
                        try await Task.sleep(for: .milliseconds(100))
                        try ui.writePreview(to: SettingsStore.reportsDirectory.appendingPathComponent("answer-oct11-\(fixture.id)-\(width).png"))
                    }
                    ui.answer.setContentSize(size)
                }
                try save(root: root)
                print("Cloud \(index+1): \(status), firstRender=\(rows.last!.firstRender ?? -1), cost=\(rows.last!.costRub ?? "unknown")")
                if index == 4, connection.supportsBalance { let balance = try await client.balance(); budget.observeKeyRemaining(balance.availableRub) }
            }
            let previewStem = (evalGemini ? "native-cloud-gemini" : "native-cloud") + (hasVisionFixtures ? "-vision" : "")
            try ui.writePreview(to: SettingsStore.reportsDirectory.appendingPathComponent("\(previewStem)-preview.png"))
            print("Cloud spent: \(budget.spentRub), reserved: \(budget.reservedRub)")
            exitCode = !rows.isEmpty && rows.count == min(10, fixtures.count) && rows.allSatisfy { $0.status == "ready" && $0.firstRender != nil } ? 0 : 1
            try saveRun(root: root, status: exitCode == 0 ? "passed" : "failed")
        } catch { exitCode = 1; try? saveRun(root: root, status: "failed", error: error.localizedDescription); print("Cloud validation failed: \(error.localizedDescription)") }
        NSApp.terminate(nil)
    }
    private func loadJPEG(path: String, root: URL) throws -> Data {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw NSError(domain: "CloudValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать изображение fixture"])
        }
        return jpeg
    }
    private func save(root: URL) throws {
        let url = SettingsStore.reportsDirectory.appendingPathComponent("\(reportStem)-validation.json")
        try JSONEncoder().encode(rows).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func saveRun(root: URL, status: String, error: String = "") throws {
        let report: [String: Any] = ["runID": UUID().uuidString, "date": ISO8601DateFormatter().string(from: Date()), "status": status, "rows": rows.count, "error": error, "model": preset.model, "reasoningEffort": preset.reasoningEffort ?? "omitted", "providerSort": preset.providerSort, "promptRevision": PromptBuilder.revision, "maxTokens": preset.maxTokens, "fontSize": model.settings.fontSize, "visionFixtures": hasVisionFixtures]
        let url = SettingsStore.reportsDirectory.appendingPathComponent("\(reportStem)-run.json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
