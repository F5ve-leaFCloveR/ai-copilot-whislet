import Foundation

@MainActor
final class ASRProcess {
    private var process: Process?
    private var directory: URL?
    private(set) var sessionID = UUID()
    var onExit: ((Int32) -> Void)?
    func start(pythonPath: String, sidecarPath: String, language: String) throws -> String {
        stop(); sessionID = UUID()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ic-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let socket = directory.appendingPathComponent("asr.sock").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [URL(fileURLWithPath: sidecarPath).appendingPathComponent("server.py").path, "--socket", socket, "--session-id", sessionID.uuidString, "--model", "moona3k/mlx-qwen3-asr-0.6b-8bit", "--language", language]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "PYTHONUNBUFFERED": "1", "TOKENIZERS_PARALLELISM": "false"]
        process.currentDirectoryURL = URL(fileURLWithPath: sidecarPath)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let instance = sessionID
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor in guard let self, self.sessionID == instance, self.process != nil else { return }; self.onExit?(status) }
        }
        try process.run(); self.process = process
        return socket
    }
    func stop() {
        if let process { process.terminationHandler = nil; if process.isRunning { process.terminate() } }
        process = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
