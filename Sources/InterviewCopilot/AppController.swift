import AppKit
import AVFoundation
import CopilotCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let model = UIModel()
    private let registry = ProtectedWindowRegistry()
    private var ui: InterviewUI!
    private var hotkeys: HotkeyRegistry!
    private var saved = SettingsStore.load()
    private var state = SessionReducer()
    private var questionGate = QuestionGate()
    private var privacy = PrivacyGate()
    private var budget = BudgetLedger(limitRub: 50)
    private let asr = ASRProcess()
    private var socket: ASRSocket?
    private var capture: AudioCapture?
    private var client: OpenAICompatibleClient?
    private var translationClient: OpenAICompatibleClient?
    private var apiConnection: APIConnection?
    private var pricedCosts: [UUID: UsageCost] = [:]
    private var startTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var pendingTranslationQuestionID: UUID?
    private var pendingManualQuestionID: UUID?
    private var healthTask: Task<Void, Never>?
    private var privacyTask: Task<Void, Never>?
    private var checkingPrivacy = false
    private var privacyOperationID: UUID?
    private var captureTransitionTask: Task<Void, Never>?
    private var epoch = UUID()
    private var ready = false
    private var running = false
    private var preparing = false
    private var lastHeartbeat = 0.0
    private var captureResetAt = 0.0
    private var latestSystem: Utterance?
    private var requestedUtteranceIDs: [UUID] = []
    private var imageCards: Set<UUID> = []
    private var cardModels: [UUID: String] = [:]
    private var cardProfiles: [UUID: UUID] = [:]
    private let projectContextStore = ProjectContextStore()
    private var finalUtterances: [Utterance] = []
    private var displayTranscript: [UUID: Utterance] = [:]
    private var transcriptOrder: [UUID] = []
    private var statusItem: NSStatusItem?
    private var presentation = UIPresentation()
    private var completedSinceBalance = 0
    private var lastBalanceAt = 0.0
    private var timings: [UUID: TimingRecord] = [:]
    private var costEntries: [CostEntry] = []
    private var observerTokens: [NSObjectProtocol] = []
    private static let translationPreviewQuestion = "Could you describe your approach to evaluating an AI assistant?"
    private static let translationPreviewText = "Можете описать ваш подход к оценке ИИ-помощника?"
    private let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--validate-native") || CommandLine.arguments.contains("--export-ui-preview")
    private let keyOverride: String?
    private var ephemeralReplay: Bool { keyOverride != nil }
    private var replay: ReplayRunner?

    init(keyOverride: String? = nil) { self.keyOverride = keyOverride; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.stop()
        model.settings = saved.ui
        if demo || ephemeralReplay {
            model.settings.profiles = nil; model.settings.selectedProfileID = nil
            model.settings.profileName = "AI Engineer"
            model.settings.profile = "Учебный профиль: Python, FastAPI, RAG, PostgreSQL, Docker. Практический опыт Kubernetes и количественные результаты не указаны."
            model.settings.vacancy = ""
            model.settings.migrateProfiles()
        }
        if ephemeralReplay {
            model.settings.shareMode = "Без демонстрации"; model.settings.auto = true
            model.settings.model = CommandLine.arguments.contains("--eval-gemini") ? "gemini-3.5-flash-lite" : "claude-haiku-5.5"
        }
        if !NSScreen.screens.contains(where: { displayID($0) == model.settings.displayID }) { model.settings.displayID = CGMainDisplayID() }
        saved.ui = model.settings
        presentation.displays = NSScreen.screens.enumerated().map { UIDisplayOption(id: displayID($0.element), name: "Экран \($0.offset + 1) · \($0.element.localizedName)") }
        presentation.isDemo = demo
        presentation.keyStatus = demo || ephemeralReplay ? "Preview · без Keychain" : "Проверка ключа…"
        for confirmation in saved.confirmations where confirmation.version == serviceVersion() {
            privacy.confirm(service: confirmation.service, mode: shareMode(confirmation.mode), displayID: confirmation.displayID, version: confirmation.version)
        }
        registry.canShow = { [weak self] kind in
            guard let self else { return false }
            if self.demo { return true }
            if kind == .setup || kind == .settings || kind == .context, !self.running { return true }
            return self.canShow()
        }
        model.onAction = { [weak self] action in self?.handle(action) }
        model.onProfileChanged = { [weak self] old, new in self?.profileChanged(from: old, to: new) }
        model.onContentRendered = { [weak self] id, time in
            guard let self, self.timings[id] != nil, self.timings[id]?.firstRender == nil else { return }
            self.timings[id]?.firstRender = time
            self.replay?.rendered(id: id, timing: self.timings[id]!)
        }
        ui = InterviewUI(model: model, registry: registry)
        hotkeys = HotkeyRegistry()
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        configureHotkeys()
        asr.onExit = { [weak self] _ in guard let self, self.running || self.preparing else { return }; self.captureFailed("Распознавание остановилось. Нажмите «Восстановить»") }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Whislet")
        statusItem?.button?.target = self; statusItem?.button?.action = #selector(statusClicked)
        observeEnvironment()
        render()
        if demo {
            ui.showToolbar()
            if CommandLine.arguments.contains("--demo") { ui.showSetup() }
        } else {
            ui.showSetup()
            Task { [weak self] in
                do {
                    let stored = try await Task.detached(priority: .utility) { try KeychainStore.hasStoredKey() }.value
                    self?.presentation.keyStatus = stored ? "Ключ сохранён в Keychain" : "Добавьте API key"
                } catch { self?.presentation.keyStatus = "Ключ не проверен · повторите при запуске" }
                self?.render()
            }
        }
        traceLayout()
        if demo, CommandLine.arguments.contains("--translation-preview") { prepareTranslationPreview() }
        if CommandLine.arguments.contains("--validate-native") || CommandLine.arguments.contains("--export-ui-preview") { Task { await nativeValidation() } }
        if let index = CommandLine.arguments.firstIndex(of: "--replay"), CommandLine.arguments.indices.contains(index + 1) {
            replay = ReplayRunner(manifestPath: CommandLine.arguments[index + 1], controller: self)
            replay?.begin()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelTranslation()
        startTask?.cancel(); requestTask?.cancel(); manualTask?.cancel(); healthTask?.cancel(); socket?.close(); asr.stop()
        observerTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        if !demo, !ephemeralReplay { saved.ui = model.settings; try? SettingsStore.save(saved) }
    }
    @objc private func statusClicked() {
        if demo || canShow() { state.show(); ui.showToolbar() } else { ui.showSetup() }
    }
    private func handle(_ action: UIAction) {
        switch action {
        case .quit: NSApp.terminate(nil)
        case .cancelHint: cancelGeneration(); state.cancel(); presentation.phase = .listening; render()
        case .startStop:
            if running || preparing { stop() } else { start() }
        case .manual(let input): manual(input)
        case .translateQuestion: translateQuestion()
        case .dismissTranslation: cancelTranslation(); render()
        case .screenshot: manual(nil, screenshot: true)
        case .pause: pause()
        case .hide: state.hide(); ui.hideAll()
        case .previous:
            guard !state.cards.isEmpty else { return }
            let current = state.cards.firstIndex { $0.id == state.selectedCardID } ?? state.cards.count - 1
            state.selectHistory(state.cards[max(0, current - 1)].id); presentation.answerRevealRevision &+= 1; render(); ui.showAnswer()
        case .latest: state.showLatest(); presentation.answerRevealRevision &+= 1; render(); ui.showAnswer()
        case .settings: ui.showSettings()
        case .context: ui.showContext()
        case .history: ui.showHistory()
        case .selectHistory(let id): state.selectHistory(id); presentation.answerRevealRevision &+= 1; render(); ui.showAnswer()
        case .pinHistory: if let id = state.selectedCardID { state.selectHistory(id); render() }
        case .setAuto(let value): model.settings.auto = value; saveSettings(model.settings)
        case .setModel(let value): model.settings.model = value; saveSettings(model.settings)
        case .saveSettings(let settings): saveSettings(settings)
        case .saveKey(let value):
            guard !demo, !ephemeralReplay else { return }
            if running || preparing { stop() }
            let token = epoch
            Task {
                do {
                    let connection = try APIConnection.resolve(apiKey: value, explicitBaseURL: model.settings.apiBaseURL, strictSchema: model.settings.strictJSONSchema ?? true)
                    try await Task.detached(priority: .userInitiated) { try KeychainStore.save(value) }.value
                    guard token == epoch else { return }
                    apiConnection = connection
                    model.settings.adaptDefaultModel(to: connection)
                    saved.ui = model.settings; try SettingsStore.save(saved)
                    presentation.keyStatus = "Ключ сохранён в Keychain"; presentation.error = ""; render()
                } catch { fail(error.localizedDescription) }
            }
        case .windowLayout(let layout): model.settings.layout = layout; if !demo, !ephemeralReplay { saved.ui = model.settings; try? SettingsStore.save(saved) }; traceLayout()
        case .checkPrivacy: checkPrivacy()
        case .confirmPrivacy: confirmPrivacy()
        case .recover: stop(); start()
        case .moreDetail:
            guard let question = currentProfileCard?.question ?? manualAudioSelection?.question else { localMessage("Сначала выберите вопрос"); return }
            state.show(); generate(question, long: true)
        }
    }
    private func configureHotkeys() {
        if model.settings.hotkeysEnabled, !ephemeralReplay { presentation.hotkeyError = hotkeys.registerDefaults(overrides: model.settings.hotkeyLetters).joined(separator: "\n") } else { hotkeys.unregister(); presentation.hotkeyError = "" }
    }
    private func saveSettings(_ value: UISettings) {
        if ephemeralReplay { model.settings = saved.ui; render(); return }
        if demo { model.settings = value; render(); return }
        let old = saved.ui
        model.settings = value
        let changedPrivacy = old.displayID != value.displayID || old.service != value.service || old.shareMode != value.shareMode
        if changedPrivacy {
            privacy.markLocalPreflight(displayID: value.displayID, passed: false)
            presentation.localCapturePassed = false; presentation.privacyConfirmed = false
            ui.hideAll()
            if running || preparing { stop() }
        }
        if old.language != value.language, running || preparing { stop() }
        if old.apiBaseURL != value.apiBaseURL || old.strictJSONSchema != value.strictJSONSchema {
            if running || preparing { stop() }
            apiConnection = nil
        }
        saved.ui = value
        do { try SettingsStore.save(saved) } catch { presentation.error = error.localizedDescription }
        if old.hotkeysEnabled != value.hotkeysEnabled || old.hotkeyLetters != value.hotkeyLetters { configureHotkeys() }
        render(); if changedPrivacy { ui.showSetup() }
    }
    private func profileChanged(from old: UUID?, to new: UUID) {
        guard old != new else { return }
        cancelTranslation()
        cancelGeneration(); state.resetConversation(); questionGate.reset()
        cardProfiles.removeAll(); cardModels.removeAll(); imageCards.removeAll()
        latestSystem = nil; finalUtterances.removeAll(); displayTranscript.removeAll(); transcriptOrder.removeAll(); requestedUtteranceIDs.removeAll()
        captureResetAt = ProcessInfo.processInfo.systemUptime; socket?.reset()
        presentation.error = ""
        if running { presentation.phase = state.isPaused ? .paused : .listening }
        render()
    }
    private var currentProfileCard: HintCard? {
        guard let card = state.selectedCard, cardProfiles[card.id] == model.settings.activeProfile.id else { return nil }
        return card
    }
    private var audioSnapshot: [Utterance] {
        ManualQuestionSelector.select(from: finalUtterances + Array(displayTranscript.values))?.context ?? []
    }
    private var manualAudioSelection: ManualQuestionSelection? {
        var current = audioSnapshot.filter { $0.endedAt >= captureResetAt }
        if let latestSystem, latestSystem.endedAt >= captureResetAt { current.append(latestSystem) }
        return ManualQuestionSelector.select(from: current)
    }
    private var translationQuestion: Utterance? {
        Self.latestInterviewerQuestion(from: audioSnapshot, latestSystem: latestSystem, after: captureResetAt)
    }
    nonisolated static func latestInterviewerQuestion(from utterances: [Utterance], latestSystem: Utterance?, after cutoff: Double) -> Utterance? {
        let current = utterances + (latestSystem.map { [$0] } ?? [])
        return ManualQuestionSelector.select(from: current.filter { $0.source == .system && $0.endedAt >= cutoff })?.question
    }
    private func start() {
        if demo { running = true; state.resume(); presentation.phase = .listening; render(); ui.showToolbar(); return }
        guard !running, !preparing, !checkingPrivacy, privacyTask == nil else { return }
        let profile = profileText()
        guard profile.utf8.count <= 12000 else { fail("Профиль и вакансия длиннее 12 000 bytes. Сократите контекст"); return }
        epoch = UUID(); let token = epoch
        preparing = true; presentation.phase = .warming; presentation.error = ""; render()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let key: String
                if let keyOverride { key = keyOverride }
                else {
                    guard let stored = try await Task.detached(priority: .userInitiated, operation: { try KeychainStore.read() }).value, !stored.isEmpty else { throw appError("Добавьте API key в подготовке") }
                    key = stored
                }
                guard token == epoch, !Task.isCancelled else { return }
                try await AudioCapture.requestPermissions()
                guard token == epoch, !Task.isCancelled else { return }
                if !presentation.localCapturePassed { try await runPreflight(includeControl: true) }
                guard token == epoch, !Task.isCancelled else { return }
                guard canShow() else { throw appError("Подтвердите проверку этой трансляции на втором устройстве либо выберите «Без демонстрации»") }
                let connection = try APIConnection.resolve(apiKey: key, explicitBaseURL: model.settings.apiBaseURL, strictSchema: model.settings.strictJSONSchema ?? true)
                apiConnection = connection
                model.settings.adaptDefaultModel(to: connection)
                let client = OpenAICompatibleClient(keyProvider: { key }, connection: connection)
                self.client = client
                translationClient = OpenAICompatibleClient(keyProvider: { key }, connection: connection)
                budget = BudgetLedger(limitRub: replay == nil ? 50 : 10); pricedCosts.removeAll()
                if connection.supportsBalance {
                    let balance = try await client.balance()
                    guard token == epoch, !Task.isCancelled else { return }
                    budget.observeKeyRemaining(balance.availableRub)
                }
                lastBalanceAt = ProcessInfo.processInfo.systemUptime; completedSinceBalance = 0
                render()
                try await startASR(token: token)
                guard token == epoch, !Task.isCancelled else { return }
                state = SessionReducer(); questionGate.reset(); finalUtterances.removeAll(); latestSystem = nil; captureResetAt = ProcessInfo.processInfo.systemUptime
                let capture = makeCapture(); self.capture = capture
                if replay == nil { try await capture.start(displayID: model.settings.displayID) }
                guard token == epoch, !Task.isCancelled else { await capture.stop(); return }
                running = true; preparing = false; presentation.phase = .listening
                presentation.audioStatus = "Звук созвона и микрофон подключены"; presentation.asrStatus = "Qwen3-ASR готов"
                presentation.error = ""; registry.closeAuxiliary(); state.show(); render(); ui.showToolbar()
                startHealthMonitor(token: token)
            } catch {
                guard token == epoch else { return }
                preparing = false; socket?.close(); socket = nil; asr.stop(); ready = false
                await capture?.stop(); capture = nil
                fail(error.localizedDescription); ui.showSetup()
            }
        }
    }
    private func startASR(token: UUID) async throws {
        guard token == epoch, !Task.isCancelled else { throw CancellationError() }
        ready = false; presentation.asrStatus = "Прогреваю Qwen3-ASR…"; render()
        let sidecar = sidecarDirectory()
        guard FileManager.default.isExecutableFile(atPath: saved.pythonPath) else { throw appError("Python runtime не найден: пересоберите приложение на этом Mac") }
        let path = try asr.start(pythonPath: saved.pythonPath, sidecarPath: sidecar, language: model.settings.language)
        let instance = asr.sessionID
        let connection = try await ASRSocket.connect(path: path, sessionID: instance, onMessage: { [weak self] message in
            Task { @MainActor in guard let self, self.epoch == token, self.asr.sessionID == instance else { return }; self.receive(message) }
        }, onFailure: { [weak self] message in Task { @MainActor in guard let self, self.epoch == token else { return }; self.captureFailed(message) } })
        guard token == epoch, !Task.isCancelled else { connection.close(); throw CancellationError() }
        socket = connection
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while !ready {
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw appError("Модель не прогрелась за минуту. Восстановите ASR") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func makeCapture() -> AudioCapture {
        let token = epoch
        return AudioCapture(packet: { [weak self] packet in
            Task { @MainActor in
                guard let self, self.epoch == token, (self.running && !self.state.isPaused) || self.preparing, packet.capturedAt >= self.captureResetAt else { return }
                self.socket?.send(packet)
                let rms = sqrt(packet.samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, packet.samples.count)))
                if packet.source == .system { self.presentation.systemLevel = min(1, rms * 8) } else { self.presentation.microphoneLevel = min(1, rms * 8) }
                self.render()
            }
        }, failure: { [weak self] message in Task { @MainActor in guard let self, self.epoch == token else { return }; self.captureFailed(message) } })
    }
    private func receive(_ message: ASRMessage) {
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        switch message.kind {
        case "ready": ready = true
        case "heartbeat": break
        case "error":
            if message.code == "long_utterance" { localMessage("Длинная реплика. Используйте «Ответ AI» по последнему тексту") }
            else { captureFailed(message.message ?? message.code ?? "Ошибка распознавания") }
        case "transcript":
            guard running, !state.isPaused, let id = message.id, let source = message.source, let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard (message.endedAt ?? 0) >= captureResetAt else { return }
            let utterance = Utterance(id: id, source: source, text: text, endedAt: message.endedAt ?? ProcessInfo.processInfo.systemUptime, isFinal: message.isFinal ?? false)
            receiveUtterance(utterance)
        default: break
        }
    }
    func receiveUtterance(_ utterance: Utterance) {
        guard running, !state.isPaused, utterance.endedAt >= captureResetAt else { return }
        if displayTranscript[utterance.id] == nil { transcriptOrder.append(utterance.id) }
        displayTranscript[utterance.id] = utterance
        if transcriptOrder.count > 200 { displayTranscript.removeValue(forKey: transcriptOrder.removeFirst()) }
        if utterance.source == .system {
            latestSystem = utterance
            if let current = translationQuestion, presentation.translation.question != nil {
                if pendingTranslationQuestionID == current.id { presentation.translation.updateQuestion(current) }
                else if !presentation.translation.matches(current) { cancelTranslation() }
            }
        }
        if utterance.isFinal {
            finalUtterances.append(utterance); if finalUtterances.count > 200 { finalUtterances.removeFirst() }
            state.appendTranscript(utterance)
            let accepted = questionGate.accept(utterance)
            replay?.observed(utterance, triggered: accepted && model.settings.auto)
            if accepted, model.settings.auto, pendingManualQuestionID != utterance.id, !requestedUtteranceIDs.contains(utterance.id) { generate(utterance) }
        }
        render()
    }
    private func translateQuestion() {
        guard running, !state.isPaused else { localMessage("Начните сессию или снимите паузу"); return }
        guard demo || canShow(), !checkingPrivacy, privacyTask == nil else { return }
        guard let question = translationQuestion else { showTranslationError("Пока нет реплики собеседника для перевода"); return }
        if presentation.translation.matches(question), [.streaming, .ready].contains(presentation.translation.status) {
            revealTranslation(); return
        }
        if demo {
            cancelTranslation()
            let id = presentation.translation.begin(question)
            presentation.translation.apply(.text(id, question.text == Self.translationPreviewQuestion ? Self.translationPreviewText : question.text))
            presentation.translation.apply(.done(id, costRub: 0, finishReason: "stop"))
            revealTranslation(); return
        }
        guard let translationClient, let connection = apiConnection else { showTranslationError("Сеть не подготовлена. Восстановите сессию"); return }
        cancelTranslation()
        let id = presentation.translation.begin(question)
        let token = epoch, profileID = model.settings.activeProfile.id
        let preset = ModelPreset(model: model.settings.model, reasoningEffort: ModelPreset.defaultReasoningEffort(for: model.settings.model), providerSort: "latency", maxTokens: 1024, structuredShort: false)
        pendingTranslationQuestionID = question.isFinal ? nil : question.id
        revealTranslation()
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == epoch, presentation.translation.requestID == id { translationTask = nil; pendingTranslationQuestionID = nil }
            }
            do {
                let settled = question.isFinal ? question : try await Self.settledManualQuestion(question) { self.audioSnapshot }
                try Task.checkCancellation()
                guard token == epoch, running, !state.isPaused, profileID == model.settings.activeProfile.id,
                      presentation.translation.requestID == id, translationQuestion?.id == settled.id else { return }
                presentation.translation.updateQuestion(settled); pendingTranslationQuestionID = nil
                if connection.supportsBalance, completedSinceBalance >= 5 || ProcessInfo.processInfo.systemUptime - lastBalanceAt >= 300 {
                    let balance = try await translationClient.balance()
                    try Task.checkCancellation()
                    guard token == epoch, presentation.translation.requestID == id else { return }
                    budget.observeKeyRemaining(balance.availableRub); lastBalanceAt = ProcessInfo.processInfo.systemUptime; completedSinceBalance = 0
                }
                guard token == epoch, running, !state.isPaused, profileID == model.settings.activeProfile.id,
                      presentation.translation.requestID == id, canShow(), !checkingPrivacy, privacyTask == nil else { return }
                if connection.supportsBalance { try budget.authorize(id: id, reserveRub: 1) }
                costEntries.append(CostEntry(id: id, reservedRub: connection.supportsBalance ? "1" : "0", actualRub: nil, date: Date())); saveCostJournal()
                let request = HintRequest(id: id, question: settled, preset: preset, connection: connection, purpose: .questionTranslation)
                for try await event in await translationClient.generate(request) {
                    guard token == epoch else { return }
                    if case .usage(let eventID, let cost) = event {
                        budget.settle(id: eventID, actualRub: cost)
                        if let index = costEntries.firstIndex(where: { $0.id == eventID }) { costEntries[index].actualRub = NSDecimalNumber(decimal: cost).stringValue }; saveCostJournal()
                    }
                    if case .pricedUsage(let eventID, let cost) = event {
                        pricedCosts[eventID] = cost
                        if let index = costEntries.firstIndex(where: { $0.id == eventID }) {
                            costEntries[index].actualAmount = NSDecimalNumber(decimal: cost.amount).stringValue
                            costEntries[index].currency = cost.currency
                        }
                        saveCostJournal()
                    }
                    if case .done(let eventID, let cost, _) = event {
                        if let cost {
                            budget.settle(id: eventID, actualRub: cost)
                            if let index = costEntries.firstIndex(where: { $0.id == eventID }) { costEntries[index].actualRub = NSDecimalNumber(decimal: cost).stringValue }; saveCostJournal()
                        }
                        completedSinceBalance += 1
                    }
                    guard profileID == model.settings.activeProfile.id, presentation.translation.requestID == id, !Task.isCancelled else { continue }
                    presentation.translation.apply(event); render()
                }
                guard token == epoch, profileID == model.settings.activeProfile.id, presentation.translation.requestID == id, !Task.isCancelled else { return }
                presentation.translation.apply(.done(id, costRub: nil, finishReason: "incomplete")); render()
            } catch is CancellationError { }
            catch {
                guard token == epoch, profileID == model.settings.activeProfile.id, presentation.translation.requestID == id else { return }
                presentation.translation.apply(.failed(id, error.localizedDescription)); render()
            }
        }
    }
    private func revealTranslation() {
        state.show(); presentation.answerRevealRevision &+= 1; render(); ui.showToolbar(); ui.showAnswer()
    }
    private func showTranslationError(_ message: String) {
        cancelTranslation(); presentation.translation.fail(message); revealTranslation()
    }
    private func cancelTranslation() {
        let id = presentation.translation.requestID, client = translationClient
        translationTask?.cancel(); translationTask = nil; pendingTranslationQuestionID = nil
        presentation.translation.clear()
        if let id, let client { Task { await client.cancel(id) } }
    }
    private func manual(_ text: String?, screenshot: Bool = false) {
        manualTask?.cancel(); manualTask = nil; pendingManualQuestionID = nil
        guard running, !state.isPaused else { localMessage("Начните сессию или снимите паузу"); return }
        let question: Utterance
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { question = Utterance(source: .microphone, text: text, endedAt: ProcessInfo.processInfo.systemUptime, isFinal: true) }
        else if let selected = manualAudioSelection { question = selected.question }
        else if screenshot { question = Utterance(source: .system, text: "Объясни задачу на скриншоте и предложи решение", endedAt: ProcessInfo.processInfo.systemUptime, isFinal: true) }
        else { presentation.answerRevealRevision &+= 1; localMessage("Пока нет вопроса. Введите его в поле ответа"); ui.showAnswer(); return }
        if !question.isFinal, !screenshot {
            let token = epoch, profileID = model.settings.activeProfile.id
            pendingManualQuestionID = question.id
            manualTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let settled = try await Self.settledManualQuestion(question) { self.audioSnapshot }
                    try Task.checkCancellation()
                    guard token == epoch, running, !state.isPaused, profileID == model.settings.activeProfile.id else { return }
                    manualTask = nil; pendingManualQuestionID = nil
                    finishManual(settled, text: text, screenshot: screenshot)
                } catch { }
            }
            return
        }
        finishManual(question, text: text, screenshot: screenshot)
    }
    static func settledManualQuestion(_ initial: Utterance, timeout: TimeInterval = 2, snapshot: () -> [Utterance]) async throws -> Utterance {
        var question = initial
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            if let updated = snapshot().first(where: { $0.id == initial.id }) { question = updated }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if question.isFinal || remaining <= 0 { return question }
            try await Task.sleep(for: .seconds(min(0.05, remaining)))
        }
    }
    private func finishManual(_ question: Utterance, text: String?, screenshot: Bool) {
        if Self.shouldReuseActiveAnswer(question, in: state, screenshot: screenshot) {
            state.show(); state.showLatest(); presentation.answerRevealRevision &+= 1; render(); ui.showToolbar(); ui.showAnswer(); return
        }
        if question.isFinal { _ = questionGate.accept(question) }
        let previousHint = screenshot ? nil : question.source == .microphone ? currentProfileCard : HintRequest.clarificationContext(for: text, selectedCard: currentProfileCard)
        state.show(); generate(question, screenshot: screenshot, previousHint: previousHint)
    }
    nonisolated static func shouldReuseActiveAnswer(_ question: Utterance, in state: SessionReducer, screenshot: Bool) -> Bool {
        guard let active = state.latestCard, state.activeRequestID != nil, !screenshot else { return false }
        return active.question.id == question.id && active.question.text == question.text
    }
    private func generate(_ question: Utterance, screenshot: Bool = false, long: Bool = false, previousHint: HintCard? = nil) {
        guard running, !state.isPaused else { return }
        let dialogueHint = previousHint ?? (model.settings.activeProfile.kind == .recruiterInterview ? state.latestCard : nil)
        if demo {
            let id = state.begin(question: question)
            cardProfiles[id] = model.settings.activeProfile.id
            presentation.error = ""
            presentation.answerRevealRevision &+= 1
            state.apply(.text(id, "**Краткий ответ:** Сначала уточню цель и ограничения, затем предложу решение и объясню, где оно подходит.\n\n**Детализированное объяснение**\nРазберу основные шаги, проверю крайние случаи и покажу результат на небольшом примере. Если есть несколько вариантов, сравню их по сложности, скорости и стоимости."))
            state.apply(.done(id, costRub: 0, finishReason: "stop")); render(); if !state.isHidden { ui.showAnswer() }; return
        }
        guard canShow(), !checkingPrivacy, privacyTask == nil else { return }
        guard let client, let connection = apiConnection else { fail("Сеть не подготовлена. Восстановите сессию"); return }
        let old = state.activeRequestID; requestTask?.cancel()
        if let old { Task { await client.cancel(old) } }
        let id = state.begin(question: question)
        cardProfiles[id] = model.settings.activeProfile.id
        presentation.answerRevealRevision &+= 1
        replay?.requested(id: id)
        requestedUtteranceIDs.append(question.id); if requestedUtteranceIDs.count > 32 { requestedUtteranceIDs.removeFirst() }
        do { if connection.supportsBalance { try budget.authorize(id: id, reserveRub: 1) } }
        catch { state.apply(.failed(id, error.localizedDescription)); presentation.phase = .budgetLimit; presentation.error = error.localizedDescription; render(); if !state.isHidden { ui.showAnswer() }; replay?.completed(id: id, timing: nil, card: state.latestCard); return }
        costEntries.append(CostEntry(id: id, reservedRub: connection.supportsBalance ? "1" : "0", actualRub: nil, date: Date())); saveCostJournal()
        timings[id] = TimingRecord(id: id, questionEnd: question.endedAt, asrFinal: ProcessInfo.processInfo.systemUptime)
        presentation.phase = .generating; presentation.error = ""; render(); if !state.isHidden { ui.showToolbar(); ui.showAnswer() }
        cardModels[id] = model.settings.model
        let token = epoch, needsImage = screenshot || ScreenshotCapture.needsScreenReference(question.text)
        let preset = ModelPreset(model: model.settings.model, reasoningEffort: ModelPreset.defaultReasoningEffort(for: model.settings.model), providerSort: "latency", maxTokens: 2048, structuredShort: !long)
        let profile = profileText(), context = audioSnapshot
        let selectedProfile = model.settings.activeProfile
        let mode = selectedProfile.kind.conversationMode
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { replay?.completed(id: id, timing: timings[id], card: state.cards.first { $0.id == id }) }
            do {
                if connection.supportsBalance, completedSinceBalance >= 5 || ProcessInfo.processInfo.systemUptime - lastBalanceAt >= 300 {
                    let balance = try await client.balance()
                    guard token == epoch, state.activeRequestID == id, !Task.isCancelled else { return }
                    budget.observeKeyRemaining(balance.availableRub); lastBalanceAt = ProcessInfo.processInfo.systemUptime; completedSinceBalance = 0
                }
                if connection.supportsBalance { try budget.validateReservation(id: id) }
                var jpeg: Data?
                if needsImage { jpeg = try await ScreenshotCapture.capture(displayID: model.settings.displayID); imageCards.insert(id); render() }
                try Task.checkCancellation()
                guard token == epoch, state.activeRequestID == id, canShow(), !checkingPrivacy, privacyTask == nil, !state.isPaused else { return }
                timings[id]?.requestStart = ProcessInfo.processInfo.systemUptime
                let projectContext = mode == .work ? try await projectContextStore.context(path: selectedProfile.knowledgeFile, question: question.text, recent: context, previousHint: dialogueHint) : ""
                try Task.checkCancellation()
                guard token == epoch, state.activeRequestID == id else { return }
                let request = HintRequest(id: id, question: question, context: context, profile: profile, preset: preset, jpeg: jpeg, previousHint: dialogueHint, mode: mode, projectContext: mode == .work ? projectContext : "", connection: connection)
                let stream = await client.generate(request)
                jpeg = nil
                for try await event in stream {
                    guard token == epoch else { return }
                    if case .usage(let eventID, let cost) = event {
                        budget.settle(id: eventID, actualRub: cost)
                        if let index = costEntries.firstIndex(where: { $0.id == eventID }) { costEntries[index].actualRub = NSDecimalNumber(decimal: cost).stringValue }; saveCostJournal()
                    }
                    if case .pricedUsage(let eventID, let cost) = event {
                        pricedCosts[eventID] = cost
                        if let index = costEntries.firstIndex(where: { $0.id == eventID }) {
                            costEntries[index].actualAmount = NSDecimalNumber(decimal: cost.amount).stringValue
                            costEntries[index].currency = cost.currency
                        }
                        saveCostJournal()
                    }
                    if case .done(let eventID, let cost, _) = event {
                        if let cost { budget.settle(id: eventID, actualRub: cost); if let index = costEntries.firstIndex(where: { $0.id == eventID }) { costEntries[index].actualRub = NSDecimalNumber(decimal: cost).stringValue }; saveCostJournal() }
                        timings[eventID]?.requestDone = ProcessInfo.processInfo.systemUptime; completedSinceBalance += 1
                    }
                    guard state.activeRequestID == id else { continue }
                    if case .text = event, timings[id]?.firstContent == nil { timings[id]?.firstContent = ProcessInfo.processInfo.systemUptime }
                    state.apply(event); render()

                }
                guard token == epoch else { return }
                if state.activeRequestID == id { state.apply(.done(id, costRub: nil, finishReason: "incomplete")); render() }
                if state.activeRequestID == nil { presentation.phase = .listening; render() }
            } catch is CancellationError { }
            catch {
                guard token == epoch, state.activeRequestID == id else { return }
                state.apply(.failed(id, error.localizedDescription)); presentation.phase = .listening
                presentation.error = error.localizedDescription; render()
            }
        }
    }
    private func pause() {
        guard running, captureTransitionTask == nil else { return }
        if state.isPaused {
            let token = epoch
            captureTransitionTask = Task {
                defer { if token == epoch { captureTransitionTask = nil } }
                do { captureResetAt = ProcessInfo.processInfo.systemUptime; socket?.reset(); try await capture?.start(displayID: model.settings.displayID); guard epoch == token else { return }; state.resume(); presentation.phase = .listening; render() }
                catch is CancellationError { }
                catch { guard token == epoch else { return }; captureFailed(error.localizedDescription) }
            }
        } else {
            cancelTranslation()
            cancelGeneration(); state.pause(); captureResetAt = ProcessInfo.processInfo.systemUptime; socket?.reset(); latestSystem = nil
            let token = epoch, old = capture
            captureTransitionTask = Task { await old?.stop(); if token == epoch { captureTransitionTask = nil } }; presentation.phase = .paused; presentation.audioStatus = "Захват на паузе"; render()
        }
    }
    private func stop() {
        cancelTranslation(); translationClient = nil
        epoch = UUID(); captureTransitionTask?.cancel(); captureTransitionTask = nil; privacyTask?.cancel(); privacyTask = nil; privacyOperationID = nil; startTask?.cancel(); startTask = nil; cancelGeneration(); healthTask?.cancel(); healthTask = nil
        running = false; preparing = false; ready = false
        socket?.close(); socket = nil; asr.stop()
        let old = capture; capture = nil; Task { await old?.stop() }
        state.stop(); questionGate.reset(); latestSystem = nil; requestedUtteranceIDs.removeAll(); imageCards.removeAll(); cardModels.removeAll(); cardProfiles.removeAll(); finalUtterances.removeAll(); displayTranscript.removeAll(); transcriptOrder.removeAll()
        presentation.phase = .stopped; presentation.text = ""; presentation.question = ""; presentation.error = ""
        presentation.asrStatus = "Распознавание не запущено"; presentation.audioStatus = "Захват остановлен"; presentation.systemLevel = 0; presentation.microphoneLevel = 0
        ui.stop(); render(); if demo || canShow() { ui.showToolbar() } else { ui.showSetup() }
    }
    private func cancelGeneration() {
        manualTask?.cancel(); manualTask = nil; pendingManualQuestionID = nil
        requestTask?.cancel(); requestTask = nil
        if let id = state.activeRequestID, let client { Task { await client.cancel(id) } }
    }
    private func captureFailed(_ text: String) {
        guard running || preparing else { return }
        cancelTranslation(); translationClient = nil
        epoch = UUID(); captureTransitionTask?.cancel(); captureTransitionTask = nil; startTask?.cancel(); startTask = nil
        cancelGeneration(); state.pause(); ready = false; running = false; preparing = false
        socket?.close(); socket = nil; asr.stop(); healthTask?.cancel()
        let old = capture; capture = nil; Task { await old?.stop() }
        presentation.phase = .failed; presentation.error = text; presentation.asrStatus = "ASR остановлен"; render()
        if !canShow() { registry.hideAll(); ui.showSetup() }
    }
    private func checkPrivacy() {
        if demo { presentation.localCapturePassed = true; presentation.privacyStatus = "Preview: защита внешней трансляции не проверена"; render(); return }
        guard !running else { localMessage("Завершите сессию перед повторной проверкой защиты"); return }
        guard !preparing, !checkingPrivacy, privacyTask == nil else { return }
        let active = running, token = epoch, operation = UUID()
        if active { cancelGeneration(); state.cancel(); presentation.phase = .listening }
        privacyOperationID = operation
        privacyTask = Task {
            defer { if privacyOperationID == operation { privacyTask = nil; privacyOperationID = nil } }
            do {
                try await AudioCapture.requestPermissions()
                guard token == epoch else { return }
                try await runPreflight(includeControl: !active)
                render(); if active && canShow() { ui.showToolbar() } else if !active { ui.showSetup() }
            } catch {
                guard token == epoch else { return }
                privacy.markLocalPreflight(displayID: model.settings.displayID, passed: false); presentation.localCapturePassed = false; registry.hideAll()
                if running { captureFailed(error.localizedDescription) } else { fail(error.localizedDescription) }
                ui.showSetup()
            }
        }
    }
    private func runPreflight(includeControl: Bool) async throws {
        guard !checkingPrivacy else { throw appError("Проверка защиты уже выполняется") }
        checkingPrivacy = true; defer { checkingPrivacy = false }
        let display = model.settings.displayID, service = model.settings.service, mode = model.settings.shareMode, token = epoch
        registry.hideAll(); ui.prepareAllWindows()
        let windows = registry.windows.compactMap { window -> (String, NSWindow)? in guard let kind = registry.kind(of: window) else { return nil }; return (kind.rawValue, window) }
        let result = try await CapturePreflight.run(windows: windows, displayID: display, includeControl: includeControl)
        guard token == epoch, display == model.settings.displayID, service == model.settings.service, mode == model.settings.shareMode, !Task.isCancelled else { throw CancellationError() }
        privacy.markLocalPreflight(displayID: result.displayID, passed: result.passed)
        presentation.localCapturePassed = result.passed
        let data = try JSONEncoder().encode(result); try SettingsStore.writeDiagnostic(data, filename: "capture-preflight.json")
        guard result.passed else { throw appError("Локальная проверка защиты не прошла. Панели скрыты") }
        presentation.privacyStatus = "Локальный захват: окна исключены"
        render()
    }
    private func confirmPrivacy() {
        guard !demo, !ephemeralReplay else { return }
        guard !checkingPrivacy, !preparing, privacyTask == nil else { return }
        guard presentation.localCapturePassed else { localMessage("Сначала выполните локальную проверку защиты"); return }
        let version = serviceVersion()
        privacy.confirm(service: model.settings.service, mode: shareMode(model.settings.shareMode), displayID: model.settings.displayID, version: version)
        saved.confirmations.removeAll { $0.service == model.settings.service && $0.mode == model.settings.shareMode && $0.displayID == model.settings.displayID }
        saved.confirmations.append(SavedPrivacyConfirmation(service: model.settings.service, mode: model.settings.shareMode, displayID: model.settings.displayID, version: version, checkedAt: Date()))
        try? SettingsStore.save(saved); render()
    }
    private func canShow() -> Bool {
        privacy.canShowPanel(service: model.settings.service, mode: shareMode(model.settings.shareMode), displayID: model.settings.displayID, version: serviceVersion())
    }
    private func shareMode(_ value: String) -> ShareMode {
        if value == "Без демонстрации" { return .none }
        if value == "Окно" { return .window }
        return .fullDisplay
    }
    private func serviceVersion() -> String {
        let service = model.settings.service.lowercased()
        let path: String
        if service.contains("zoom") { path = "/Applications/zoom.us.app" }
        else if service.contains("teams") { path = "/Applications/Microsoft Teams.app" }
        else { path = "/Applications/Google Chrome.app" }
        let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "не установлен"
        return "0.1.0|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(path)|\(version)"
    }
    private func profileText() -> String {
        let label: String
        switch model.settings.activeProfile.kind {
        case .work: label = "Цель разговора и дополнительные вводные:"
        case .interview: label = "Вакансия и требования:"
        case .recruiterInterview: label = "Формат интервью и ограничения:"
        }
        return model.settings.profile + (model.settings.vacancy.isEmpty ? "" : "\n" + label + "\n" + model.settings.vacancy)
    }
    private func fail(_ message: String) { presentation.phase = .failed; presentation.error = message; render() }
    private func localMessage(_ message: String) { presentation.error = message; render() }
    private func sidecarDirectory() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sidecar")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("server.py").path) { return bundled.path }
        return SettingsStore.projectDirectory.appendingPathComponent("sidecar").path
    }
    private func render() {
        let card = state.selectedCard ?? state.latestCard
        presentation.question = card?.question.text ?? ""; presentation.text = card?.text ?? ""
        presentation.followups = card?.followups ?? []
        presentation.hintStatus = status(card?.status ?? .waiting)
        presentation.selectedCardID = card?.id
        presentation.hasScreenshot = card.map { imageCards.contains($0.id) } ?? false
        presentation.screenshotLabel = presentation.hasScreenshot ? "Снимок прикреплён" : ""
        presentation.selectedIndex = state.cards.firstIndex { $0.id == card?.id } ?? 0
        presentation.pendingCount = state.pendingCardID == nil ? 0 : 1
        presentation.isReadingHistory = state.isReadingHistory
        presentation.transcript = transcriptOrder.compactMap { displayTranscript[$0] }.map { UITranscriptItem(id: $0.id, speaker: $0.source == .system ? "Собеседник" : "Вы", text: $0.text, time: $0.isFinal ? "" : "…") }
        presentation.history = state.cards.map { UIHistoryItem(id: $0.id, question: $0.question.text, text: $0.text, status: status($0.status), model: cardModels[$0.id] ?? model.settings.model, hasScreenshot: imageCards.contains($0.id)) }
        let connection = apiConnection ?? (try? APIConnection.resolve(apiKey: "", explicitBaseURL: model.settings.apiBaseURL, strictSchema: model.settings.strictJSONSchema ?? true)) ?? .openAI
        presentation.apiEndpoint = connection.baseURL.absoluteString; presentation.apiDialect = connection.dialect
        if connection.supportsBalance {
            presentation.budgetText = "\(NSDecimalNumber(decimal: budget.spentRub).stringValue) ₽ / \(NSDecimalNumber(decimal: budget.limitRub).stringValue) ₽" + (budget.reservedRub > 0 ? " · резерв \(NSDecimalNumber(decimal: budget.reservedRub).stringValue) ₽" : "")
        } else {
            let amount = pricedCosts.values.reduce(Decimal(0)) { $0 + $1.amount }
            let currency = pricedCosts.values.first?.currency
            presentation.budgetText = currency.map { "\(NSDecimalNumber(decimal: amount).stringValue) \($0) · \(completedSinceBalance) запросов" } ?? "Стоимость не предоставлена · \(completedSinceBalance) запросов"
        }
        presentation.privacyConfirmed = canShow()
        model.apply(presentation); ui?.refresh()
    }
    private func status(_ value: HintStatus) -> UIHintStatus {
        switch value { case .waiting: .waiting; case .streaming: .streaming; case .ready: .ready; case .cancelled: .cancelled; case .incomplete: .incomplete; case .failed: .failed }
    }
    private func displayID(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
    private func startHealthMonitor(token: UUID) {
        healthTask?.cancel(); healthTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, token == epoch else { return }
                if ProcessInfo.processInfo.systemUptime - lastHeartbeat > 8 { captureFailed("ASR не отвечает. Нажмите «Восстановить»"); return }
                if !CGPreflightScreenCaptureAccess() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { captureFailed("Разрешение на захват отозвано"); return }
            }
        }
    }
    private func observeEnvironment() {
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.captureFailed("Mac уснул. После пробуждения восстановите ASR") } })
        for name in [AVCaptureDevice.wasDisconnectedNotification, AVCaptureDevice.wasConnectedNotification, NSApplication.didChangeScreenParametersNotification] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.running else { return }; self.captureFailed("Устройство или экран изменились. Восстановите захват") } })
        }
    }
    private func saveCostJournal() { if let data = try? JSONEncoder().encode(costEntries) { try? SettingsStore.writeDiagnostic(data, filename: "session-cost.json") } }
    private func traceLayout() {
        guard demo, CommandLine.arguments.contains("--trace-layout"), let ui else { return }
        let values: [String: Double] = ["toolbarX": ui.toolbar.frame.minX, "toolbarY": ui.toolbar.frame.minY, "answerX": ui.answer.frame.minX, "answerY": ui.answer.frame.minY, "answerWidth": ui.answer.frame.width, "answerHeight": ui.answer.frame.height, "gap": ui.toolbar.frame.minY - ui.answer.frame.maxY, "centerDelta": ui.toolbar.frame.midX - ui.answer.frame.midX]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) { print("UI layout: " + String(decoding: data, as: UTF8.self)) }
    }
    private func prepareTranslationPreview() {
        running = true; state.resume(); presentation.phase = .listening
        let question = Utterance(source: .system, text: Self.translationPreviewQuestion, endedAt: ProcessInfo.processInfo.systemUptime, isFinal: true)
        latestSystem = question
        let id = state.begin(question: question)
        state.apply(.text(id, "I compare the answers with reference questions and check correctness, grounding and response time."))
        state.apply(.done(id, costRub: 0, finishReason: "stop"))
        cardProfiles[id] = model.settings.activeProfile.id
        presentation.answerRevealRevision &+= 1
        registry.closeAuxiliary(); render(); ui.showToolbar(); ui.showAnswer()
    }
    private func appError(_ text: String) -> NSError { NSError(domain: "InterviewCopilot", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    private func nativeValidation() async {
        var checks: [String: Bool] = [:]
        var geometry: [String: String] = [:]
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        running = true; state.resume(); presentation.phase = .listening
        presentation.asrStatus = "Preview · звук и API отключены"
        let question = Utterance(source: .system, text: "Зачем в RAG нужен reranker?", endedAt: ProcessInfo.processInfo.systemUptime, isFinal: true)
        let id = state.begin(question: question)
        let sample = "**Краткий ответ:** **Reranker** заново оценивает найденные документы вместе с вопросом и поднимает наиболее релевантные. Это убирает неподходящие фрагменты из верхних позиций.\n\n**Детализированное объяснение**\n1. **Как работает**\n   - Retrieval быстро отбирает кандидатов из большой базы.\n   - Reranker точнее сравнивает пары «вопрос — документ» и меняет порядок.\n2. **Где ограничение**\n   - Он не возвращает документ, которого первый этап не нашёл.\n   - Дополнительный этап увеличивает latency и стоимость.\n3. **Как проверить пользу**\n   - Сравнить MRR, nDCG и качество ответов на одном размеченном наборе.\n   - Одновременно измерить latency: выигрыш должен оправдывать задержку."
        state.apply(.text(id, sample))
        state.apply(.done(id, costRub: 0, finishReason: "stop")); render(); ui.showAnswer()
        try? await Task.sleep(for: .milliseconds(250))
        checks["focus_preserved"] = front == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let a = ui.answer.frame, t = ui.toolbar.frame
        ui.toggleQuickSettings()
        ui.toolbar.setFrameOrigin(NSPoint(x: t.minX + 70, y: t.minY - 35))
        try? await Task.sleep(for: .milliseconds(100))
        checks["answer_follows_toolbar"] = abs(ui.answer.frame.minX - a.minX - 70) < 1 && abs(ui.answer.frame.minY - a.minY + 35) < 1
        checks["quick_closes_on_toolbar_move"] = !ui.quickSettings.isVisible
        let beforeAnswerMove = ui.toolbar.frame
        let answerBeforeMove = ui.answer.frame
        geometry["toolbarBeforeAnswerMove"] = NSStringFromRect(beforeAnswerMove)
        geometry["answerBeforeMove"] = NSStringFromRect(ui.answer.frame)
        geometry["answerRequestedOrigin"] = NSStringFromPoint(NSPoint(x: ui.answer.frame.minX + 30, y: ui.answer.frame.minY - 15))
        ui.answer.setFrameOrigin(NSPoint(x: ui.answer.frame.minX + 30, y: ui.answer.frame.minY - 15))
        geometry["toolbarAfterAnswerMove"] = NSStringFromRect(ui.toolbar.frame)
        geometry["answerAfterMove"] = NSStringFromRect(ui.answer.frame)
        let answerDelta = NSPoint(x: ui.answer.frame.minX - answerBeforeMove.minX, y: ui.answer.frame.minY - answerBeforeMove.minY)
        let toolbarDelta = NSPoint(x: ui.toolbar.frame.minX - beforeAnswerMove.minX, y: ui.toolbar.frame.minY - beforeAnswerMove.minY)
        checks["answer_move_moves_group"] = abs(answerDelta.x - toolbarDelta.x) < 1 && abs(answerDelta.y - toolbarDelta.y) < 1 && abs(answerDelta.x - 30) <= 1 && abs(answerDelta.y + 15) <= 1
        checks["answer_has_fixed_anchor"] = abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1 && abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1 && !ui.answer.isMovableByWindowBackground
        ui.closeAnswer()
        let offset = ui.answerOffset
        ui.toolbar.setFrameOrigin(NSPoint(x: ui.toolbar.frame.minX - 40, y: ui.toolbar.frame.minY - 20))
        ui.showAnswer()
        checks["answer_restore_attachment"] = ui.answer.parent === ui.toolbar && abs(ui.answer.frame.minX - ui.toolbar.frame.minX - offset.x) < 1
        ui.answer.setContentSize(NSSize(width: 760, height: 490))
        checks["answer_resizes"] = abs(ui.answer.frame.width - 760) < 1 && abs(ui.answer.frame.height - 490) < 1
        checks["resize_keeps_fixed_anchor"] = abs(ui.answer.frame.midX - ui.toolbar.frame.midX) < 1 && abs(ui.answer.frame.maxY + 12 - ui.toolbar.frame.minY) < 1
        ui.hideAll(); ui.showAnswer()
        checks["hide_restore_attachment"] = ui.answer.parent === ui.toolbar
        checks["all_registered_protected"] = registry.windows.count == 7 && registry.windows.allSatisfy { $0.sharingType == .none }
        let next = Utterance(source: .system, text: "Как работает async?", endedAt: ProcessInfo.processInfo.systemUptime, isFinal: true)
        let active = state.begin(question: next)
        latestSystem = next; state.selectHistory(id)
        let count = state.cards.count, revision = presentation.answerRevealRevision
        manual(nil)
        checks["manual_reveals_active_answer_without_duplicate"] = state.selectedCardID == active && state.cards.count == count && presentation.answerRevealRevision > revision && !state.isReadingHistory
        state.selectHistory(id)
        let automaticRevision = presentation.answerRevealRevision
        generate(question)
        checks["new_generation_reveals_latest_answer"] = state.selectedCardID == state.latestCard?.id && !state.isReadingHistory && presentation.answerRevealRevision > automaticRevision
        state.stop(); state.resume()
        let previewID = state.begin(question: question)
        state.apply(.text(previewID, sample)); state.apply(.suggestions(previewID, ["Покажи пример работы reranker", "Как подобрать число кандидатов?", "Как оценить выигрыш по nDCG?"])); state.apply(.done(previewID, costRub: 0, finishReason: "stop"))
        presentation.answerRevealRevision &+= 1; render()
        ui.answer.setContentSize(NSSize(width: 680, height: 460)); ui.showAnswer()
        try? await Task.sleep(for: .milliseconds(200))
        let root = SettingsStore.reportsDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try ui.writePreview(to: root.appendingPathComponent("native-ui-preview.png")) } catch { checks["preview_saved"] = false }
        if CommandLine.arguments.contains("--validate-native") {
            do {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw CaptureError.screenPermission }
                registry.hideAll()
                let result = try await CapturePreflight.run(windows: registry.windows.map { (registry.kind(of: $0)!.rawValue, $0) }, displayID: model.settings.displayID, includeControl: true)
                checks["local_capture_preflight"] = result.passed
                let data = try JSONEncoder().encode(result); try data.write(to: root.appendingPathComponent("native-capture-preflight.json"), options: [.atomic])
            } catch { checks["local_capture_preflight"] = false; print(error.localizedDescription) }
        }
        let output: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString, "checks": checks, "geometry": geometry, "remotePrivacy": "unverified", "hotkeyConflicts": presentation.hotkeyError]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("native-validation.json"), options: [.atomic]) }
        print("Native validation: \(checks)")
        if checks.values.contains(false) { exit(1) }
        NSApp.terminate(nil)
    }

    func startReplay() { start() }
    var replayReady: Bool { running && ready && !state.isPaused }
    var replayFailed: String? { presentation.phase == .failed ? presentation.error : nil }
    func sendReplayPacket(_ packet: AudioPacket) { socket?.send(packet) }
    func beginReplayCase() {
        cancelGeneration(); state.cancel(); questionGate.reset(); latestSystem = nil
        captureResetAt = ProcessInfo.processInfo.systemUptime; socket?.reset()
    }
    func replayStop() { stop() }
}

struct TimingRecord: Codable {
    let id: UUID
    let questionEnd: Double
    let asrFinal: Double
    var requestStart: Double?
    var firstContent: Double?
    var firstRender: Double?
    var requestDone: Double?
}
struct CostEntry: Codable {
    let id: UUID
    let reservedRub: String
    var actualRub: String?
    let date: Date
    var actualAmount: String?
    var currency: String?
}
