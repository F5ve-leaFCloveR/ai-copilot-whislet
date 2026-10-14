import AppKit
import AVFoundation
import CopilotCore

struct ReplayCase: Decodable {
    let id: String
    let audioPath: String
    let source: AudioSource
    let start: Double
    let duration: Double
    let expectedQuestion: Bool
    let referenceText: String?
    let waveformEnd: Double?
}

@MainActor
final class ReplayRunner {
    private let manifestPath: String
    private weak var controller: AppController?
    private var task: Task<Void, Never>?
    private var current: ReplayCase?
    private var rows: [[String: Any]] = []
    private var sequence: [AudioSource: Int] = [:]
    private var caseStarted = 0.0
    private var triggers = 0
    private var finals = 0
    private var currentQuestionID: UUID?
    private var requestCases: [UUID: String] = [:]
    private var pendingRequests: Set<UUID> = []
    private var requestEnds: [UUID: (source: Double, speech: Double?)] = [:]
    private var sourceEnd = 0.0
    private var knownSpeechEnd: Double?
    init(manifestPath: String, controller: AppController) { self.manifestPath = manifestPath; self.controller = controller }
    func begin() {
        task = Task {
            do {
                try save()
                let data = try String(contentsOfFile: manifestPath, encoding: .utf8)
                let cases = try data.split(separator: "\n").map { try JSONDecoder().decode(ReplayCase.self, from: Data($0.utf8)) }
                guard !cases.isEmpty else { throw error("Пустой replay manifest") }
                controller?.startReplay()
                let deadline = ProcessInfo.processInfo.systemUptime + 90
                while controller?.replayReady != true {
                    if let failure = controller?.replayFailed { throw error(failure) }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw error("Replay: сессия не подготовлена") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                for item in cases {
                    try Task.checkCancellation()
                    current = item; triggers = 0; finals = 0; currentQuestionID = nil
                    controller?.beginReplayCase(); sequence.removeAll()
                    let samples = try read(item)
                    caseStarted = ProcessInfo.processInfo.systemUptime
                    sourceEnd = caseStarted + Double(samples.count) / 16_000
                    knownSpeechEnd = item.waveformEnd.map { caseStarted + $0 - item.start }
                    let packetEnd = caseStarted + ceil(Double(samples.count) / 8000) * 0.5
                    for offset in stride(from: 0, to: samples.count, by: 8000) {
                        let source = item.source
                        let number = (sequence[source] ?? 0) + 1; sequence[source] = number
                        var part = Array(samples[offset..<min(samples.count, offset + 8000)])
                        if part.count < 8000 { part += Array(repeating: 0, count: 8000 - part.count) }
                        try await wait(until: caseStarted + Double(offset + 8000) / 16_000)
                        controller?.sendReplayPacket(AudioPacket(source: source, sequence: number, samples: part, capturedAt: caseStarted + Double(offset) / 16_000))
                    }
                    for index in 0..<3 {
                        let number = (sequence[item.source] ?? 0) + 1; sequence[item.source] = number
                        try await wait(until: packetEnd + Double(index + 1) * 0.5)
                        controller?.sendReplayPacket(AudioPacket(source: item.source, sequence: number, samples: Array(repeating: 0, count: 8000), capturedAt: packetEnd + Double(index) * 0.5))
                    }
                    try await Task.sleep(for: .seconds(1))
                    let requestDeadline = ProcessInfo.processInfo.systemUptime + 25
                    while pendingRequests.contains(where: { requestCases[$0] == item.id }) {
                        try checkHealth()
                        guard ProcessInfo.processInfo.systemUptime < requestDeadline else {
                            rows.append(["caseID": item.id, "kind": "timeout"]); try save(); throw error("Replay: ответ не завершился за25с")
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try checkHealth()
                    rows.append(["caseID": item.id, "kind": "case", "source": item.source.rawValue, "expectedQuestion": item.expectedQuestion, "triggered": triggers > 0, "triggerCount": triggers, "finalCount": finals, "sourceEnd": sourceEnd])
                    try save()
                    current = nil
                }
                controller?.replayStop(); try save()
                print("Replay complete: \(cases.count) cases")
                NSApp.terminate(nil)
            } catch {
                rows.append(["kind": "run_failed", "message": error.localizedDescription]); try? save()
                print("Replay failed: \(error.localizedDescription)"); controller?.replayStop(); exit(1)
            }
        }
    }
    func requested(id: UUID) {
        guard let current else { return }
        requestCases[id] = current.id; pendingRequests.insert(id)
        requestEnds[id] = (sourceEnd, knownSpeechEnd)
        rows.append(["caseID": current.id, "kind": "request", "requestID": id.uuidString])
    }
    func observed(_ utterance: Utterance, triggered: Bool) {
        guard let current, utterance.source == current.source else { return }
        finals += 1
        if triggered { triggers += 1; currentQuestionID = utterance.id }
        rows.append(["caseID": current.id, "kind": "asr_final", "source": utterance.source.rawValue, "triggered": triggered, "endedAt": utterance.endedAt, "asrFinalAt": ProcessInfo.processInfo.systemUptime])
    }
    func rendered(id: UUID, timing: TimingRecord) {
        guard let caseID = requestCases[id] else { return }
        var row: [String: Any] = ["caseID": caseID, "kind": "render", "requestID": id.uuidString, "questionEnd": timing.questionEnd, "firstRender": timing.firstRender ?? 0, "sourceEnd": requestEnds[id]?.source ?? 0]
        row["knownSpeechEnd"] = requestEnds[id]?.speech; rows.append(row)
    }
    func completed(id: UUID, timing: TimingRecord?, card: HintCard?) {
        guard let caseID = requestCases[id] else { return }
        pendingRequests.remove(id)
        var row: [String: Any] = ["caseID": caseID, "kind": "completion", "requestID": id.uuidString]
        if let timing { row["questionEnd"] = timing.questionEnd; row["asrFinal"] = timing.asrFinal; row["requestStart"] = timing.requestStart; row["firstContent"] = timing.firstContent; row["firstRender"] = timing.firstRender; row["requestDone"] = timing.requestDone }
        if let card { row["status"] = String(describing: card.status); row["words"] = card.text.split(whereSeparator: \.isWhitespace).count }
        rows.append(row); try? save()
    }
    private func wait(until deadline: Double) async throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        try Task.checkCancellation()
        try checkHealth()
    }
    private func checkHealth() throws {
        if let failure = controller?.replayFailed { throw error(failure) }
        guard controller?.replayReady == true else { throw error("Replay: захват или ASR остановлен") }
    }
    private func read(_ item: ReplayCase) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: item.audioPath))
        guard abs(file.processingFormat.sampleRate - 16000) < 1, file.processingFormat.channelCount == 1 else { throw error("Replay принимает mono WAV16kHz") }
        file.framePosition = AVAudioFramePosition(item.start * 16000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(item.duration * 16000)) else { throw error("Не удалось прочитать replay audio") }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw error("Не удалось прочитать PCM") }
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
    private func save() throws {
        let output = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().appendingPathComponent("results.jsonl")
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        try data.write(to: output, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
    private func error(_ text: String) -> NSError { NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
