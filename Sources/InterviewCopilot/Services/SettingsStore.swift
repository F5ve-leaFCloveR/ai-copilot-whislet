import Foundation

struct SavedPrivacyConfirmation: Codable {
    var service: String
    var mode: String
    var displayID: UInt32
    var version: String
    var checkedAt: Date
}
struct SavedSettings: Codable {
    var ui = UISettings()
    var pythonPath = SettingsStore.defaultPythonPath
    var confirmations: [SavedPrivacyConfirmation] = []

    private enum CodingKeys: String, CodingKey { case ui, pythonPath, confirmations }
    init() {}
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ui = try container.decodeIfPresent(UISettings.self, forKey: .ui) ?? UISettings()
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath) ?? pythonPath
        confirmations = try container.decodeIfPresent([SavedPrivacyConfirmation].self, forKey: .confirmations) ?? []
        ui.migrateProfiles()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var value = ui; value.syncActiveProfile()
        try container.encode(value, forKey: .ui)
        try container.encode(pythonPath, forKey: .pythonPath)
        try container.encode(confirmations, forKey: .confirmations)
    }
}

@MainActor
enum SettingsStore {
    nonisolated static var projectDirectory: URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle.deletingLastPathComponent().deletingLastPathComponent() }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    nonisolated static var defaultPythonPath: String { projectDirectory.appendingPathComponent("sidecar/.venv/bin/python").path }
    static var reportsDirectory: URL { directory.appendingPathComponent("reports/validation") }
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InterviewCopilot")
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static func load() -> SavedSettings {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(SavedSettings.self, from: data) else { return SavedSettings() }
        return settings
    }
    static func save(_ settings: SavedSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }
    static func writeDiagnostic(_ data: Data, filename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(filename)
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
