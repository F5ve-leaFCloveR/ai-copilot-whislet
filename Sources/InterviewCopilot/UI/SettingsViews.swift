import SwiftUI

struct SettingsSurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    @State var section = "Общие"
    @State private var key = ""
    private let sections: [(String, String)] = [("Общие", "gearshape"), ("Горячие клавиши", "keyboard"), ("Экран", "display"), ("Звук", "mic"), ("Контекст", "doc.text"), ("О программе", "info.circle")]

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Настройки", close: close)
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(sections, id: \.0) { title, symbol in
                        Button { section = title } label: {
                            HStack(spacing: 12) { Image(systemName: symbol).foregroundStyle(section == title ? UITheme.accentText : UITheme.muted).frame(width: 18); Text(title); Spacer(minLength: 0) }
                                .padding(.horizontal, 16).frame(height: 43).background(section == title ? Color.white.opacity(0.06) : .clear)
                                .overlay(alignment: .leading) { if section == title { UITheme.accent.frame(width: 3) } }
                        }.buttonStyle(.plain).font(.system(size: 14))
                    }
                    Spacer()
                }.padding(.top, 8).frame(width: 200).background(UITheme.group)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(section).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        switch section {
                        case "Общие": general
                        case "Горячие клавиши": hotkeys
                        case "Экран": screen
                        case "Звук": sound
                        case "Контекст": ProfileEditor(model: model)
                        default: about
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.frame(maxWidth: .infinity)
            }
        }.foregroundStyle(UITheme.text).background(UITheme.base).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            group("ОСНОВНЫЕ") {
                settingRow("Язык", detail: "Распознавание и формат ответа") {
                    InlineSelector(value: model.settings.language == "Russian" ? "Русский" : "English", options: ["Русский", "English"], width: 160) { model.settings.language = $0 == "Русский" ? "Russian" : "English"; model.saveSettings() }
                }
                settingRow("Автоматические ответы", detail: "Речь собеседника запускает подсказку") { ToggleControl(on: model.settings.auto) { model.settings.auto.toggle(); model.send(.setAuto(model.settings.auto)) } }
            }
            group("ВИД ОКНА") {
                VStack(alignment: .leading, spacing: 8) { HStack { Text("Прозрачность"); Spacer(); Text("\(Int(model.settings.opacity * 100))%").foregroundStyle(UITheme.accentText) }; Slider(value: $model.settings.opacity, in: 0.5...1, onEditingChanged: { editing in if !editing { model.saveSettings() } }).tint(UITheme.accent) }
                VStack(alignment: .leading, spacing: 8) { HStack { Text("Размер шрифта"); Spacer(); Text("\(Int(model.settings.fontSize)) pt").foregroundStyle(UITheme.accentText) }; Slider(value: $model.settings.fontSize, in: 10...24, step: 1, onEditingChanged: { editing in if !editing { model.saveSettings() } }).tint(UITheme.accent) }
            }
            group("ПОДКЛЮЧЕНИЕ") {
                Text(model.presentation.keyStatus).font(.system(size: 13)).foregroundStyle(UITheme.muted)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Адрес API · Base URL")
                    TextField("Автоматически по ключу", text: Binding(get: { model.settings.apiBaseURL ?? "" }, set: { model.settings.apiBaseURL = $0.isEmpty ? nil : $0 })).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7)).font(.system(size: 13)).onSubmit { model.saveSettings() }
                    Text("Оставьте пустым для автоматического выбора. Текущий адрес: \(model.presentation.apiEndpoint)").font(.system(size: 11)).foregroundStyle(UITheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Модель · точный ID")
                    TextField("gpt-4.1-mini", text: $model.settings.model).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7)).font(.system(size: 13)).onSubmit { model.send(.setModel(model.settings.model.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.modelChoices, id: \.self) { value in
                                Button(UIModel.modelName(value)) { model.settings.model = value; model.send(.setModel(value)) }.buttonStyle(FlatButtonStyle()).font(.system(size: 11))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                settingRow("Строгий формат ответа", detail: "Отключите, если ваш сервис не поддерживает JSON Schema") { ToggleControl(on: model.settings.strictJSONSchema ?? true) { model.settings.strictJSONSchema = !(model.settings.strictJSONSchema ?? true); model.saveSettings() } }
                Button("Применить настройки подключения") { model.settings.model = model.settings.model.trimmingCharacters(in: .whitespacesAndNewlines); model.saveSettings() }.buttonStyle(FlatButtonStyle())
                SecureField("API key · OpenAI-совместимый сервис", text: $key).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7)).font(.system(size: 13))
                HStack { Text("Хранение только в macOS Keychain").font(.system(size: 11)).foregroundStyle(UITheme.muted); Spacer(); Button("Сохранить ключ") { let value = key.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { model.saveSettings(); model.send(.saveKey(value)); key = "" } }.buttonStyle(FlatButtonStyle(primary: true)).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }

    private var hotkeys: some View {
        group("УПРАВЛЕНИЕ") {
            settingRow("Горячие клавиши", detail: "Физические клавиши, RU и EN layout") { ToggleControl(on: model.settings.hotkeysEnabled) { model.settings.hotkeysEnabled.toggle(); model.saveSettings() } }
            Text("Выберите букву A–Z для каждой команды. Control + Option остаются фиксированными в первой версии.").font(.system(size: 12)).foregroundStyle(UITheme.muted)
            ForEach(UIHotkeys.commands) { command in
                HStack(alignment: .top) {
                    Text(command.title).padding(.top, 6); Spacer()
                    Text("⌃⌥").font(.system(size: 12)).foregroundStyle(UITheme.muted).padding(.top, 7)
                    HotkeyLetterSelector(value: model.settings.hotkeyLetter(command.id), title: command.title) { value in
                        var letters = model.settings.hotkeyLetters ?? [:]
                        if value == command.defaultLetter { letters.removeValue(forKey: command.id) } else { letters[command.id] = value }
                        model.settings.hotkeyLetters = letters.isEmpty ? nil : letters
                        model.saveSettings()
                    }.frame(width: 215)
                }
            }
            Button("Вернуть стандартные комбинации") { model.settings.hotkeyLetters = nil; model.saveSettings() }.buttonStyle(FlatButtonStyle())
            if !model.presentation.hotkeyError.isEmpty { Text(model.presentation.hotkeyError).font(.system(size: 12)).foregroundStyle(.orange) }
        }
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 24) {
            group("ДЕМОНСТРАЦИЯ") {
                settingRow("Сервис", detail: "Подтверждение отдельно для каждого сервиса") { InlineSelector(value: model.settings.service, options: ["Zoom", "Яндекс Телемост", "Microsoft Teams", "Google Meet", "F1 / Meets", "Другой сервис"], width: 185) { model.settings.service = $0; model.saveSettings() } }
                settingRow("Что демонстрируете") { InlineSelector(value: model.settings.shareMode, options: ["Весь экран", "Окно", "Вкладка", "Без демонстрации"], width: 185) { model.settings.shareMode = $0; model.saveSettings() } }
                settingRow("Дисплей") { displaySelector }
            }
            group("ПРОВЕРКА ТРАНСЛЯЦИИ") {
                Label(model.presentation.localCapturePassed ? "Локальный capture: проверка пройдена" : "Локальный capture: проверка не завершена", systemImage: "display").font(.system(size: 13))
                Text(model.presentation.privacyStatus).font(.system(size: 13)).foregroundStyle(UITheme.muted)
                Text("Проверьте все окна со второго устройства в приватном звонке. Локальный capture не подтверждает поведение Zoom, Teams или другого сервиса.").font(.system(size: 12)).foregroundStyle(UITheme.muted).fixedSize(horizontal: false, vertical: true)
                HStack { Button("Локальная проверка") { model.send(.checkPrivacy) }.buttonStyle(FlatButtonStyle()); Button("Проверил со второго устройства") { model.send(.confirmPrivacy) }.buttonStyle(FlatButtonStyle(primary: true)).disabled(!model.presentation.localCapturePassed && !model.presentation.isDemo) }
                if model.presentation.isDemo { Text("Демонстрационный режим не проверяет трансляцию и не подключает аудио/API").font(.system(size: 11)).foregroundStyle(UITheme.muted) }
            }
        }
    }

    private var displaySelector: some View {
        let displays = model.presentation.displays
        return InlineSelector(value: displays.first(where: { $0.id == model.settings.displayID })?.name ?? "Основной экран", options: displays.isEmpty ? ["Основной экран"] : displays.map(\.name), width: 185) { value in model.settings.displayID = displays.first(where: { $0.name == value })?.id ?? 0; model.saveSettings() }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 24) {
            group("ИСТОЧНИКИ ЗВУКА") {
                Text(model.presentation.audioStatus).foregroundStyle(UITheme.muted)
                level("Собеседник", value: model.presentation.systemLevel)
                level("Микрофон", value: model.presentation.microphoneLevel)
                Text("Микрофон доступен как контекст и не запускает Auto").font(.system(size: 12)).foregroundStyle(UITheme.muted)
            }
            group("РАСПОЗНАВАНИЕ") { Text(model.presentation.asrStatus).font(.system(size: 13)); HStack { Button(model.presentation.phase == .paused ? "Продолжить" : "Пауза") { model.send(.pause) }.buttonStyle(FlatButtonStyle()); Button("Восстановить") { model.send(.recover) }.buttonStyle(FlatButtonStyle()) } }
        }
    }

    private func level(_ title: String, value: Double) -> some View { HStack { Text(title).frame(width: 110, alignment: .leading); ProgressView(value: min(max(value, 0), 1)).tint(UITheme.accent); Text("\(Int(value * 100))%").font(.system(size: 11)).foregroundStyle(UITheme.muted).frame(width: 35, alignment: .trailing) } }
    private var about: some View { group("WHISLET") { Text("Помощник для интервью и рабочих разговоров").font(.system(size: 15, weight: .medium)); Text("Локальное распознавание речи и подсказки через OpenAI-совместимый API. Аудио и изображения не сохраняются по умолчанию.").font(.system(size: 13)).foregroundStyle(UITheme.muted); Text("Расход сессии: \(model.presentation.budgetText)").font(.system(size: 12)); if model.presentation.isDemo { Text("Демонстрационный режим · звук и сеть отключены").font(.system(size: 12)).foregroundStyle(UITheme.muted) } } }

    private func settingRow<Content: View>(_ title: String, detail: String = "", @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 14)); if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(UITheme.muted) } }.frame(maxWidth: .infinity, alignment: .leading); control() }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 18) { Text(title).font(.system(size: 12)).tracking(0.4).foregroundStyle(Color.gray); content() }.font(.system(size: 14)).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(UITheme.group).clipShape(RoundedRectangle(cornerRadius: 8)) }
}

private struct HotkeyLetterSelector: View {
    var value: String
    var title: String
    var select: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button { expanded.toggle() } label: { HStack { Text(value); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)) }.padding(.horizontal, 10).padding(.vertical, 6).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).accessibilityLabel("Буква для команды «\(title)»").accessibilityValue(value)
            if expanded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(UIHotkeys.letters, id: \.self) { letter in
                        Button { select(letter); expanded = false } label: { Text(letter).frame(maxWidth: .infinity).frame(height: 26).foregroundStyle(letter == value ? UITheme.accent : UITheme.text).background(letter == value ? UITheme.accent.opacity(0.12) : Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 4)) }.buttonStyle(.plain)
                    }
                }.padding(6).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }.font(.system(size: 12))
    }
}

struct ProfileSelector: View {
    @ObservedObject var model: UIModel
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.settings.activeProfile.kind == .work ? "briefcase" : "person.crop.circle")
                    Text(model.settings.profileName.isEmpty ? "Без названия" : model.settings.profileName).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).accessibilityLabel("Выбрать профиль")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.settings.availableProfiles) { profile in
                        Button {
                            model.selectProfile(profile.id)
                            expanded = false
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name.isEmpty ? "Без названия" : profile.name).lineLimit(2)
                                    Text(profile.kind.title).font(.system(size: 10)).foregroundStyle(UITheme.muted)
                                }
                                Spacer(minLength: 4)
                                if profile.id == model.settings.activeProfile.id { Image(systemName: "checkmark").font(.system(size: 10)) }
                            }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(profile.id == model.settings.activeProfile.id ? UITheme.accent : UITheme.text)
                    }
                }.background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7)).padding(.top, 3)
            }
        }.font(.system(size: 12)).foregroundStyle(UITheme.text)
    }
}

struct ProfileEditor: View {
    @ObservedObject var model: UIModel
    @State private var deleting = false
    private var working: Bool { model.settings.activeProfile.kind == .work }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Профиль").font(.system(size: 13))
            HStack(spacing: 6) {
                ProfileSelector(model: model)
                IconControl(symbol: "plus", label: "Добавить рабочий профиль") { model.addProfile(kind: .work) }
                IconControl(symbol: "doc.on.doc", label: "Создать копию профиля") { model.addProfile(kind: model.settings.activeProfile.kind, duplicateCurrent: true) }
                IconControl(symbol: "trash", label: "Удалить профиль") { deleting = true }.disabled(model.settings.availableProfiles.count <= 1)
            }
            Text(model.settings.activeProfile.kind.title).font(.system(size: 11)).foregroundStyle(UITheme.muted)
            TextField("Название профиля", text: $model.settings.profileName).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
            Text(working ? "Цель разговора" : "Вакансия").font(.system(size: 13))
            TextField(working ? "Тема созвона и дополнительные вводные" : "Название и требования", text: $model.settings.vacancy).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
            Text(working ? "Контекст проекта и мои вводные" : "Контекст и подтверждённые факты опыта").font(.system(size: 13))
            if working, model.settings.activeProfile.knowledgeFile != nil {
                Label("Справочник проекта подключён", systemImage: "doc.text.magnifyingglass").font(.system(size: 11)).foregroundStyle(UITheme.accentText)
            }
            TextEditor(text: $model.settings.profile).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 170).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
            if working { Text("Помощник использует факты из контекста и предлагает вариант ответа, когда данных не хватает.").font(.system(size: 11)).foregroundStyle(UITheme.muted) }
            HStack { Text("Действует со следующего ответа").font(.system(size: 11)).foregroundStyle(UITheme.muted); Spacer(); Button("Сохранить") { model.saveSettings() }.buttonStyle(FlatButtonStyle(primary: true)) }
        }.font(.system(size: 14)).foregroundStyle(UITheme.text)
            .alert("Удалить профиль?", isPresented: $deleting) {
                Button("Удалить", role: .destructive) { model.deleteActiveProfile() }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Контекст этого профиля будет удалён. Остальные профили сохранятся.") }
    }
}

struct ProfileSurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    var body: some View { VStack(spacing: 0) { WindowHeader(title: model.settings.activeProfile.kind == .work ? "Контекст разговора" : "Контекст интервью", close: close); ScrollView { ProfileEditor(model: model).padding(24) } }.background(UITheme.base).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1)) }
}

struct HistorySurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    var select: (UUID) -> Void
    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "История сессии", close: close)
            ScrollView {
                VStack(spacing: 0) {
                    if model.presentation.history.isEmpty { Text("Вопросы этой сессии появятся здесь").font(.system(size: 14)).foregroundStyle(UITheme.muted).padding(24) }
                    ForEach(Array(model.presentation.history.enumerated()), id: \.element.id) { index, item in
                        Button { select(item.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)").font(.system(size: 11)).foregroundStyle(UITheme.muted).frame(width: 22)
                                VStack(alignment: .leading, spacing: 6) { Text(item.question).font(.system(size: 13)).multilineTextAlignment(.leading); Text(UIModel.modelName(item.model) + (item.hasScreenshot ? " · Скриншот" : "") + (item.status == .cancelled ? " · Остановлен" : "")).font(.system(size: 11)).foregroundStyle(UITheme.muted) }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(UITheme.muted)
                            }.padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider().overlay(UITheme.border)
                    }
                }.padding(.horizontal, 20)
            }
        }.foregroundStyle(UITheme.text).background(UITheme.base).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
    }
}

struct SetupSurface: View {
    @ObservedObject var model: UIModel
    var close: () -> Void
    var settings: () -> Void
    @State private var key = ""
    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: model.settings.activeProfile.kind == .work ? "Подготовка к разговору" : "Подготовка к интервью", close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Перед разговором").font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                    Text("Проверьте контекст, звук и выбранный способ демонстрации.").font(.system(size: 13)).foregroundStyle(UITheme.muted)
                    ProfileEditor(model: model)
                    HStack {
                        SecureField("API key · OpenAI-совместимый сервис", text: $key).textFieldStyle(.plain).padding(9).background(UITheme.card).clipShape(RoundedRectangle(cornerRadius: 7))
                        Button("Сохранить в Keychain") { let value = key.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { model.saveSettings(); model.send(.saveKey(value)); key = "" } }.buttonStyle(FlatButtonStyle()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        InlineSelector(value: model.settings.service, options: ["Zoom", "Яндекс Телемост", "Microsoft Teams", "Google Meet", "F1 / Meets", "Другой сервис"]) { model.settings.service = $0; model.saveSettings() }
                        InlineSelector(value: model.settings.shareMode, options: ["Весь экран", "Окно", "Вкладка", "Без демонстрации"]) { model.settings.shareMode = $0; model.saveSettings() }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        readiness("key", model.presentation.keyStatus)
                        readiness("waveform", model.presentation.asrStatus)
                        readiness("mic", model.presentation.audioStatus)
                        readiness("shield", model.presentation.privacyStatus)
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(UITheme.group).clipShape(RoundedRectangle(cornerRadius: 8))
                    if !model.presentation.error.isEmpty { Text(model.presentation.error).font(.system(size: 13)).foregroundStyle(.orange) }
                    HStack { Button("Настройки и ключ") { settings() }.buttonStyle(FlatButtonStyle()); Button("Проверка трансляции") { model.send(.checkPrivacy) }.buttonStyle(FlatButtonStyle()); Button("Выход") { model.send(.quit) }.buttonStyle(FlatButtonStyle()); Spacer(); Button(model.presentation.phase == .warming ? "Подготовка…" : "Начать") { model.send(.startStop) }.buttonStyle(FlatButtonStyle(primary: true)).disabled(model.presentation.phase == .warming) }
                    if model.presentation.isDemo { Text("Демонстрационный режим · звук и сеть отключены").font(.system(size: 11)).foregroundStyle(UITheme.muted) }
                }.padding(24)
            }
        }.foregroundStyle(UITheme.text).background(UITheme.base).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.border, lineWidth: 1))
    }
    private func readiness(_ symbol: String, _ text: String) -> some View { Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(UITheme.muted) }
}
