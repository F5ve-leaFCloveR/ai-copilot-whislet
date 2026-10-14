import AppKit

@MainActor
final class CaptureValidation: NSObject, NSApplicationDelegate {
    private let process = ASRProcess()
    private var socket: ASRSocket?
    private var audio: AudioCapture?
    private var ready = false
    private var task: Task<Void, Never>?
    private var chunks: [String: Int] = [:]
    private var voicedChunks: [String: Int] = [:]
    private var finals: [String: Int] = [:]
    private var errors: [String] = []
    private var maxAbs = 0.0
    private var playback: Process?
    private var exitCode: Int32 = 0
    func applicationDidFinishLaunching(_ notification: Notification) { task = Task { await run() } }
    func applicationWillTerminate(_ notification: Notification) { task?.cancel(); socket?.close(); process.stop(); if playback?.isRunning == true { playback?.terminate() }; if exitCode != 0 { exit(exitCode) } }
    private func run() async {
        let root = SettingsStore.projectDirectory.path
        do {
            try save(["status": "running", "systemPassed": false, "microphoneCallbackPassed": false])
            try await AudioCapture.requestPermissions()
            let path = try process.start(pythonPath: root + "/sidecar/.venv/bin/python", sidecarPath: root + "/sidecar", language: "Russian")
            socket = try await ASRSocket.connect(path: path, sessionID: process.sessionID, onMessage: { [weak self] event in Task { @MainActor in self?.receive(event) } }, onFailure: { [weak self] message in Task { @MainActor in self?.errors.append(message) } })
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while !ready {
                guard errors.isEmpty, ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "CaptureValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "ASR не готов"]) }
                try await Task.sleep(for: .milliseconds(100))
            }
            audio = AudioCapture(packet: { [weak self] packet in Task { @MainActor in
                guard let self else { return }
                let source = packet.source.rawValue
                self.chunks[source, default: 0] += 1
                let peak = packet.samples.map { abs(Double($0)) }.max() ?? 0
                self.maxAbs = max(self.maxAbs, peak)
                if peak > 0.01 { self.voicedChunks[source, default: 0] += 1 }
                self.socket?.send(packet)
            } }, failure: { [weak self] message in Task { @MainActor in self?.errors.append(message) } })
            try await audio?.start(displayID: CGMainDisplayID())
            try await Task.sleep(for: .seconds(1))
            let playback = Process(); playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playback.arguments = ["-v", "0.15", root + "/bench/2026-10-09/interview_05m.wav"]
            playback.standardOutput = FileHandle.nullDevice; playback.standardError = FileHandle.nullDevice
            self.playback = playback; try playback.run()
            try await Task.sleep(for: .seconds(13))
            await audio?.stop(); socket?.close(); process.stop()
            let passed = (voicedChunks["system"] ?? 0) > 3 && (finals["system"] ?? 0) > 0 && (chunks["microphone"] ?? 0) > 0 && errors.isEmpty
            let result: [String: Any] = ["status": passed ? "passed" : "failed", "os": ProcessInfo.processInfo.operatingSystemVersionString, "chunks": chunks, "voicedChunks": voicedChunks, "finals": finals, "errors": errors, "maxAbsPCM": maxAbs, "systemPassed": (voicedChunks["system"] ?? 0) > 3 && (finals["system"] ?? 0) > 0 && errors.isEmpty, "microphoneCallbackPassed": (chunks["microphone"] ?? 0) > 0, "cloudRequests": 0]
            try save(result); exitCode = passed ? 0 : 1
            print("Capture validation: \(result)")
        } catch { exitCode = 1; try? save(["status": "failed", "systemPassed": false, "microphoneCallbackPassed": false, "error": error.localizedDescription]); print("Capture validation failed: \(error.localizedDescription)") }
        NSApp.terminate(nil)
    }
    private func save(_ fields: [String: Any]) throws {
        var result = fields; result["runID"] = UUID().uuidString; result["date"] = ISO8601DateFormatter().string(from: Date())
        try FileManager.default.createDirectory(at: SettingsStore.reportsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = SettingsStore.reportsDirectory.appendingPathComponent("native-audio-validation.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
    private func receive(_ event: ASRMessage) {
        if event.kind == "ready" { ready = true }
        if event.kind == "error" { errors.append(event.code ?? "ASR error") }
        if event.kind == "transcript", event.isFinal == true { finals[event.source?.rawValue ?? "unknown", default: 0] += 1 }
    }
}
