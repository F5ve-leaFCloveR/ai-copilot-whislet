import AppKit
import Carbon

@MainActor
final class HotkeyRegistry {
    var onAction: ((UIAction) -> Void)?
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private let actions: [UInt32: UIAction] = [1: .manual(nil), 2: .screenshot, 3: .hide, 4: .pause, 5: .previous, 6: .latest, 7: .translateQuestion]

    init(onAction: ((UIAction) -> Void)? = nil) { self.onAction = onAction }
    func register() -> String? { let errors = registerDefaults(); return errors.isEmpty ? nil : errors.joined(separator: "\n") }
    func performHotkey(_ id: UInt32) { if let action = actions[id] { onAction?(action) } }

    func registerDefaults(overrides: [String: String]? = nil) -> [String] {
        unregister()
        let codes: [String: UInt32] = [
            "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C),
            "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F),
            "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I),
            "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
            "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O),
            "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R),
            "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U),
            "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
            "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z)
        ]
        var errors: [String] = []
        for key in (overrides ?? [:]).keys.sorted() where !UIHotkeys.commands.contains(where: { $0.id == key }) { errors.append("Неизвестная команда горячих клавиш: \(key)") }
        var selected: [String: String] = [:]
        var bindings: [(UInt32, UInt32, String, String)] = []
        for (index, command) in UIHotkeys.commands.enumerated() {
            let letter = (overrides?[command.id] ?? command.defaultLetter).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let code = codes[letter] else { errors.append("\(command.title): выберите одну физическую букву A–Z"); continue }
            if let title = selected[letter] { errors.append("⌃⌥\(letter): «\(command.title)» совпадает с «\(title)»"); continue }
            selected[letter] = command.title
            bindings.append((UInt32(index + 1), code, letter, command.title))
        }
        guard !bindings.isEmpty else { return errors }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let id = key.id
            MainActor.assumeIsolated {
                let owner = Unmanaged<HotkeyRegistry>.fromOpaque(data).takeUnretainedValue()
                owner.performHotkey(id)
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard status == noErr else { return errors + ["Не удалось подключить горячие клавиши (\(status))"] }
        for (id, code, label, title) in bindings {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x49434F50, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) }
            else { errors.append("⌃⌥\(label) · \(title): конфликт регистрации (\(result))") }
        }
        return errors
    }

    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
