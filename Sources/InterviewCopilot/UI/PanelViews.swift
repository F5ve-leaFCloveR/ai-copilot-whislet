import AppKit
import SwiftUI

enum UITheme {
    static let base = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let group = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let card = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
    static let text = Color(red: 224 / 255, green: 224 / 255, blue: 224 / 255)
    static let muted = Color(red: 160 / 255, green: 160 / 255, blue: 160 / 255)
    static let accent = Color(red: 15 / 255, green: 118 / 255, blue: 110 / 255)
    static let accentText = Color(red: 115 / 255, green: 207 / 255, blue: 196 / 255)
    @MainActor static let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    static let border = Color.white.opacity(0.12)
}

struct FlatButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? .white : UITheme.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(primary ? UITheme.accent.opacity(configuration.isPressed ? 0.75 : 0.95) : Color.white.opacity(configuration.isPressed ? 0.13 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? Color.clear : UITheme.border, lineWidth: 1))
    }
}

struct IconControl: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 25, height: 25) }
            .buttonStyle(.plain).foregroundStyle(UITheme.muted).accessibilityLabel(label)
    }
}

struct WindowHeader: View {
    var title: String
    var close: () -> Void
    var body: some View {
        HStack { ZStack(alignment: .leading) { NativeDragRegion(); Text(title).font(.system(size: 14, weight: .semibold)).allowsHitTesting(false) }.frame(maxWidth: .infinity, alignment: .leading); IconControl(symbol: "xmark", label: "Закрыть", action: close) }
            .padding(.horizontal, 16).frame(height: 40).background(UITheme.group)
            .overlay(alignment: .bottom) { UITheme.border.frame(height: 1) }
    }
}

struct InlineSelector: View {
    var value: String
    var options: [String]
    var width: CGFloat? = nil
    var select: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) { Text(value).lineLimit(1); Spacer(minLength: 4); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)) }
                    .padding(.horizontal, 9).padding(.vertical, 6).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).accessibilityLabel("Выбрать: \(value)")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button { select(option); expanded = false } label: {
                            HStack { Text(option).lineLimit(2); Spacer(minLength: 2); if option == value { Image(systemName: "checkmark").font(.system(size: 10)) } }
                                .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(option == value ? UITheme.accentText : UITheme.text)
                    }
                }.background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 3)
            }
        }.frame(width: width).font(.system(size: 12)).foregroundStyle(UITheme.text)
    }
}

struct ToggleControl: View {
    var on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Capsule().fill(on ? UITheme.accent : Color.gray.opacity(0.6)).frame(width: 38, height: 21)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 17, height: 17).padding(2) }
        }.buttonStyle(.plain).accessibilityLabel(on ? "Выключить" : "Включить").accessibilityValue(on ? "Включено" : "Выключено")
    }
}

struct ToolbarSurface: View {
    @ObservedObject var model: UIModel
    var menu: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            ZStack { NativeDragRegion(); if let icon = UITheme.appIcon { Image(nsImage: icon).resizable().scaledToFit().allowsHitTesting(false) } else { Image(systemName: "quote.bubble.fill").foregroundStyle(UITheme.accentText).allowsHitTesting(false) } }.frame(width: 23, height: 28)
            Button { model.send(.startStop) } label: { Image(systemName: model.isRunning ? "stop.fill" : "play.fill").font(.system(size: 11)).frame(width: 32, height: 26) }
                .buttonStyle(FlatButtonStyle(primary: true)).accessibilityLabel(model.isRunning ? "Остановить сессию" : "Начать сессию")
            HStack(spacing: 3) { Image(systemName: "waveform").font(.system(size: 13)); Text("\(Int(model.presentation.systemLevel * 100))%").font(.system(size: 9)).monospacedDigit() }.foregroundStyle(model.isRunning ? UITheme.accentText : UITheme.muted).frame(width: 42)
            IconControl(symbol: model.presentation.phase == .paused ? "mic.slash" : "mic", label: model.presentation.phase == .paused ? "Продолжить" : "Пауза") { model.send(.pause) }.frame(width: 19)
            Button { model.send(.manual(nil)) } label: { Text("Ответ AI").font(.system(size: 12, weight: .medium)) }.buttonStyle(FlatButtonStyle())
            IconControl(symbol: "character.bubble", label: "Перевести вопрос") { model.send(.translateQuestion) }
                .help("Перевести вопрос · \(model.settings.hotkeyShortcut("translate"))")
            Button { model.send(.screenshot) } label: { Label("Скриншот", systemImage: "rectangle.dashed").font(.system(size: 12, weight: .medium)) }.buttonStyle(FlatButtonStyle())
            IconControl(symbol: "line.3.horizontal", label: "Открыть меню", action: menu).frame(width: 23)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UITheme.group).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(UITheme.border, lineWidth: 1))
    }
}

struct AnswerSurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    @State private var tab = "Чат"
    @State private var question = ""
    @State private var modelChoices = false
    @State private var questionExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                ForEach(["Чат", "Транскрипция", "Контекст"], id: \.self) { name in
                    Button { tab = name } label: {
                        Text(name).font(.system(size: 12)).foregroundStyle(tab == name ? UITheme.accentText : UITheme.muted)
                            .frame(height: 42).overlay(alignment: .bottom) { if tab == name { UITheme.accent.frame(height: 2) } }
                    }.buttonStyle(.plain)
                }
                NativeDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Переместить панель и ответ")
                Button("Перевод") { model.send(.translateQuestion) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(UITheme.accentText)
                    .help("Перевести вопрос · \(model.settings.hotkeyShortcut("translate"))")
                if !model.presentation.question.isEmpty {
                    IconControl(symbol: questionExpanded ? "text.bubble.fill" : "text.bubble", label: questionExpanded ? "Скрыть вопрос" : "Показать вопрос") { questionExpanded.toggle() }
                        .help(questionExpanded ? "Скрыть вопрос" : "Показать вопрос")
                }
                IconControl(symbol: "xmark", label: "Закрыть ответ", action: close)
            }.padding(.horizontal, 18).frame(height: 43).background(UITheme.group.opacity(model.settings.opacity))
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if tab == "Чат" { chat }
                        else if tab == "Транскрипция" { transcript }
                        else { context }
                    }.id("top").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 15).padding(.bottom, 18)
                }
                .onScrollPhaseChange { _, phase in if phase == .interacting && tab == "Чат" { model.send(.pinHistory) } }
                .onChange(of: model.presentation.selectedCardID) { _, _ in
                    questionExpanded = false
                    reader.scrollTo("top", anchor: .top)
                }
                .onChange(of: model.presentation.answerRevealRevision) { _, _ in
                    tab = "Чат"
                    questionExpanded = false
                    Task { @MainActor in
                        await Task.yield()
                        reader.scrollTo("top", anchor: .top)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Уточнить ответ…", text: $question).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(sendQuestion)
                IconControl(symbol: isCancelControl ? "stop.fill" : "paperplane", label: isCancelControl ? "Остановить генерацию" : "Отправить вопрос", action: sendQuestion)
            }.padding(8).background(UITheme.card.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(UITheme.border, lineWidth: 1)).padding(.horizontal, 16).padding(.bottom, 12)
            if modelChoices {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.modelChoices, id: \.self) { name in
                        Button(UIModel.modelName(name)) { model.settings.model = name; model.send(.setModel(name)); modelChoices = false }.buttonStyle(FlatButtonStyle()).font(.system(size: 11))
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            HStack(spacing: 7) {
                Button { modelChoices.toggle() } label: { Label(UIModel.modelName(model.settings.model), systemImage: "sparkle").font(.system(size: 11)) }.buttonStyle(FlatButtonStyle())
                Button { model.settings.auto.toggle(); model.send(.setAuto(model.settings.auto)) } label: { Text("Auto").font(.system(size: 11)).foregroundStyle(model.settings.auto ? UITheme.accentText : UITheme.muted) }.buttonStyle(FlatButtonStyle())
                Spacer(minLength: 0)
                if model.presentation.pendingCount > 0 { Button("Новый · \(model.presentation.pendingCount)") { model.send(.latest) }.buttonStyle(.plain).foregroundStyle(UITheme.accentText).font(.system(size: 10)) }
                IconControl(symbol: "chevron.left", label: "Предыдущий ответ") { model.send(.previous) }
                Text("\(model.presentation.history.isEmpty ? 0 : model.presentation.selectedIndex + 1) / \(model.presentation.history.count)").font(.system(size: 11)).foregroundStyle(UITheme.muted).monospacedDigit()
                IconControl(symbol: "chevron.right", label: "Последний ответ") { model.send(.latest) }
            }.padding(.horizontal, 14).frame(height: 39).background(UITheme.group.opacity(0.6)).overlay(alignment: .top) { UITheme.border.frame(height: 1) }
        }.foregroundStyle(UITheme.text).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255).opacity(model.settings.opacity)).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(UITheme.border, lineWidth: 1))
    }

    private var isCancelControl: Bool { model.isGenerating && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func sendQuestion() { let value = question.trimmingCharacters(in: .whitespacesAndNewlines); if isCancelControl { model.send(.cancelHint) } else { model.send(.manual(value.isEmpty ? nil : value)) }; question = "" }

    @ViewBuilder private var chat: some View {
        let value = model.presentation
        if value.translation.question != nil || !value.translation.error.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Label("Перевод последней реплики", systemImage: "character.bubble").font(.system(size: 11, weight: .medium)).foregroundStyle(UITheme.accentText)
                    Spacer(minLength: 0)
                    if value.translation.status == .streaming { ProgressView().controlSize(.mini) }
                    IconControl(symbol: "xmark", label: "Скрыть перевод") { model.send(.dismissTranslation) }
                }
                if let question = value.translation.question {
                    Text(question.text).font(.system(size: model.settings.fontSize - 2)).foregroundStyle(UITheme.muted).lineLimit(2)
                }
                if !value.translation.text.isEmpty {
                    NativeHintText(text: value.translation.text, fontSize: model.settings.fontSize, cardID: nil) { _, _ in }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if value.translation.status == .streaming {
                    Text("Перевожу вопрос…").font(.system(size: model.settings.fontSize)).foregroundStyle(UITheme.muted)
                }
                if !value.translation.error.isEmpty {
                    Text(value.translation.error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).foregroundStyle(UITheme.muted)
                } else if value.translation.status == .incomplete {
                    Text("Перевод не завершён. Нажмите «Перевод», чтобы повторить.").font(.system(size: 11)).foregroundStyle(UITheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(UITheme.accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
        }
        if questionExpanded, !value.question.isEmpty {
            Text(value.question).font(.system(size: model.settings.fontSize - 1)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(UITheme.muted)
        }
        if value.hintStatus != .ready && value.hintStatus != .waiting {
            Text(statusLabel).font(.system(size: 11)).foregroundStyle(UITheme.muted)
        }
        if !value.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(value.error).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                Button("Восстановить") { model.send(.recover) }.buttonStyle(.plain).foregroundStyle(UITheme.accentText)
            }
        }
        if !value.text.isEmpty {
            NativeHintContent(text: value.text, fontSize: model.settings.fontSize, cardID: value.selectedCardID) { id, time in model.onContentRendered?(id, time) }
                .frame(maxWidth: .infinity, alignment: .leading)
            if value.hintStatus == .ready && !value.followups.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Релевантные уточнения").font(.system(size: model.settings.fontSize, weight: .semibold))
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 1).fill(UITheme.accent.opacity(0.65)).frame(width: 2)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(value.followups.enumerated()), id: \.offset) { index, text in
                                Button { model.send(.manual(text)) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(index + 1)").font(.system(size: model.settings.fontSize - 1, weight: .semibold)).foregroundStyle(UITheme.accentText)
                                            .frame(width: 19, height: 19).background(UITheme.accent.opacity(0.13)).clipShape(RoundedRectangle(cornerRadius: 3))
                                        Text(text).font(.system(size: model.settings.fontSize)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(text)
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(model.isGenerating ? "Готовлю ответ…" : value.phase == .paused ? "Прослушивание на паузе" : value.phase == .stopped ? "Начните сессию" : value.translation.question != nil ? "Для подсказки нажмите «Ответ AI»." : "Слушаю собеседника. Ответ появится после вопроса.")
                .font(.system(size: model.settings.fontSize)).foregroundStyle(UITheme.muted).padding(.top, 6)
        }
    }

    private var statusLabel: String {
        switch model.presentation.hintStatus {
        case .waiting: "Ожидание вопроса"
        case .streaming: "Готовится ответ…"
        case .ready: model.presentation.isDemo ? "Пример ответа" : "Ответ"
        case .cancelled: "Генерация остановлена"
        case .incomplete: "Незавершённый ответ"
        case .failed: "Не удалось получить ответ"
        }
    }

    @ViewBuilder private var transcript: some View {
        if model.presentation.transcript.isEmpty { Text("Распознанные реплики появятся здесь").foregroundStyle(UITheme.muted) }
        ForEach(model.presentation.transcript) { item in
            VStack(alignment: .leading, spacing: 5) { Text("\(item.speaker)   \(item.time)").font(.system(size: 11)).foregroundStyle(UITheme.muted); Text(item.text).font(.system(size: model.settings.fontSize - 1)).textSelection(.enabled).padding(10).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 12)) }.frame(maxWidth: .infinity, alignment: item.speaker == "Вы" ? .trailing : .leading)
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 12) { Text(model.settings.profileName).font(.system(size: 17, weight: .medium)); if !model.settings.vacancy.isEmpty { Text(model.settings.vacancy).font(.system(size: 14)) }; if model.settings.activeProfile.knowledgeFile != nil { Label("Справочник проекта подключён", systemImage: "doc.text.magnifyingglass").font(.system(size: 12)).foregroundStyle(UITheme.accentText) }; Text(model.settings.profile.isEmpty ? (model.settings.activeProfile.kind == .work ? "Добавьте контекст проекта и вводные для разговора" : "Добавьте подтверждённые факты опыта перед интервью") : model.settings.profile).font(.system(size: 14)).foregroundStyle(UITheme.muted).textSelection(.enabled); Button("Редактировать контекст") { model.send(.context) }.buttonStyle(.plain).foregroundStyle(UITheme.accentText); Text("Изменения действуют со следующего ответа").font(.system(size: 11)).foregroundStyle(UITheme.muted) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuickSettingsSurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Быстрые настройки", close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Профиль").font(.system(size: 12)).foregroundStyle(UITheme.muted)
                    ProfileSelector(model: model)
                    Divider().overlay(UITheme.border).padding(.vertical, 5)
                    Text("Режим скриншота").font(.system(size: 12)).foregroundStyle(UITheme.muted)
                    Text("Экран").foregroundStyle(UITheme.accentText).padding(.horizontal, 10).padding(.vertical, 6).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("Снимок выбранного монитора").font(.system(size: 10)).foregroundStyle(UITheme.muted)
                    HStack { Text("Монитор").foregroundStyle(UITheme.muted).frame(width: 55, alignment: .leading); displaySelector }
                    HStack { Text("Язык").foregroundStyle(UITheme.muted).frame(width: 55, alignment: .leading); InlineSelector(value: languageLabel, options: ["Русский", "English"]) { model.settings.language = $0 == "Русский" ? "Russian" : "English"; model.saveSettings() } }
                    Divider().overlay(UITheme.border).padding(.vertical, 5)
                    quickRow("Настройки", symbol: "gearshape", action: .settings)
                    quickRow("Редактировать контекст", symbol: "doc.text", action: .context)
                    quickRow("История сессии", symbol: "clock.arrow.circlepath", action: .history)
                    Divider().overlay(UITheme.border).padding(.vertical, 5)
                    quickRow(model.presentation.phase == .paused ? "Продолжить" : "Пауза", symbol: model.presentation.phase == .paused ? "play" : "pause", shortcut: model.settings.hotkeyShortcut("pause"), action: .pause)
                    quickRow("Скрыть окна", symbol: "eye.slash", shortcut: model.settings.hotkeyShortcut("hide"), action: .hide)
                    quickRow(model.isRunning ? "Завершить сессию" : "Начать сессию", symbol: "power", action: .startStop)
                    quickRow("Выход", symbol: "rectangle.portrait.and.arrow.right", action: .quit)
                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10)
            }
            HStack { Button { model.send(.checkPrivacy) } label: { Label("Проверка трансляции", systemImage: "shield").font(.system(size: 10)) }.buttonStyle(.plain); Spacer(); Text(model.presentation.budgetText).font(.system(size: 10)) }.foregroundStyle(UITheme.muted).padding(14)
        }.foregroundStyle(UITheme.text).background(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
    }

    private var languageLabel: String { model.settings.language == "Russian" ? "Русский" : "English" }
    private var displaySelector: some View {
        let choices = model.presentation.displays
        return InlineSelector(value: choices.first(where: { $0.id == model.settings.displayID })?.name ?? "Основной экран", options: choices.isEmpty ? ["Основной экран"] : choices.map(\.name)) { value in
            model.settings.displayID = choices.first(where: { $0.name == value })?.id ?? 0; model.saveSettings()
        }
    }
    private func quickRow(_ title: String, symbol: String, shortcut: String = "", action: UIAction) -> some View {
        Button { model.send(action) } label: { HStack(spacing: 11) { Image(systemName: symbol).frame(width: 18); Text(title); Spacer(); Text(shortcut).font(.system(size: 10)).foregroundStyle(UITheme.muted) }.padding(.vertical, 7).padding(.horizontal, 9).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
