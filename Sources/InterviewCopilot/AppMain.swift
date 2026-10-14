import AppKit
import CopilotCore

@main
struct InterviewCopilotMain {
    @MainActor
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--score-question-gate"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let content = try String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)
                var gate = QuestionGate()
                for line in content.split(separator: "\n") {
                    let item = try JSONDecoder().decode(ReplayCase.self, from: Data(line.utf8))
                    let accepted = gate.accept(Utterance(source: item.source, text: item.referenceText ?? "", endedAt: 0, isFinal: true))
                    let row: [String: Any] = ["id": item.id, "expected": item.expectedQuestion, "accepted": accepted]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                }
            } catch { print("Question gate eval failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--import-key-stdin") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let key = String(data: data, encoding: .utf8), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try KeychainStore.save(key)
                print("Ключ сохранён в Keychain")
            } catch { print("Keychain: \(error.localizedDescription)") }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--validate-capture") {
            let validation = CaptureValidation()
            app.delegate = validation
            withExtendedLifetime(validation) { app.run() }
            return
        }
        if CommandLine.arguments.contains("--validate-cloud-stdin") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let key = String(data: data, encoding: .utf8), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { exit(1) }
            let validation = CloudValidation(key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            app.delegate = validation
            withExtendedLifetime(validation) { app.run() }
            return
        }
        var override: String?
        if CommandLine.arguments.contains("--key-stdin"), CommandLine.arguments.contains("--replay") {
            override = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard override?.isEmpty == false else { exit(1) }
        }
        let controller = AppController(keyOverride: override)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
