import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CopilotCore

struct AudioPacket: Sendable {
    let source: AudioSource
    let sequence: Int
    let samples: [Float]
    let capturedAt: Double
}

enum CaptureError: Error, LocalizedError {
    case screenPermission, microphonePermission, displayMissing, invalidAudio
    var errorDescription: String? {
        switch self {
        case .screenPermission: "Разрешите запись экрана в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного аудио. Если InterviewCopilot уже включён, удалите его из этого списка и добавьте актуальную сборку заново, затем полностью перезапустите приложение"
        case .microphonePermission: "Разрешите доступ к микрофону в Системных настройках → Конфиденциальность"
        case .displayMissing: "Выбранный экран отключён. Выберите доступный экран"
        case .invalidAudio: "Не удалось преобразовать звук. Восстановите захват"
        }
    }
}

private final class AudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.interviewcopilot.audio", qos: .userInitiated)
    let packet: @Sendable (AudioPacket) -> Void
    let failure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var enabled = false
    private var activeStreamID: ObjectIdentifier?
    private var converters: [AudioSource: PCMConverter] = [:]
    private var buffers: [AudioSource: [Float]] = [:]
    private var sequence: [AudioSource: Int] = [:]

    init(packet: @escaping @Sendable (AudioPacket) -> Void, failure: @escaping @Sendable (String) -> Void) { self.packet = packet; self.failure = failure }
    func enable(_ value: Bool, stream: SCStream? = nil) {
        lock.withLock { enabled = value; activeStreamID = stream.map(ObjectIdentifier.init) }
        queue.async { self.converters.removeAll(); self.buffers.removeAll(); self.sequence.removeAll() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard lock.withLock({ enabled && activeStreamID == ObjectIdentifier(stream) }) else { return }
        failure(error.localizedDescription)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard lock.withLock({ enabled && activeStreamID == ObjectIdentifier(stream) }), CMSampleBufferIsValid(sampleBuffer) else { return }
        let source: AudioSource
        switch type { case .audio: source = .system; case .microphone: source = .microphone; default: return }
        do {
            let converter = converters[source] ?? PCMConverter()
            converters[source] = converter
            let converted = try converter.convert(sampleBuffer)
            var buffer = buffers[source] ?? []
            buffer.append(contentsOf: converted)
            let now = ProcessInfo.processInfo.systemUptime
            while buffer.count >= 8000 {
                let number = (sequence[source] ?? 0) + 1; sequence[source] = number
                let firstTime = now - Double(buffer.count) / 16_000
                let chunk = Array(buffer.prefix(8000)); buffer.removeFirst(8000)
                packet(AudioPacket(source: source, sequence: number, samples: chunk, capturedAt: firstTime))
            }
            buffers[source] = buffer
        } catch { failure(error.localizedDescription) }
    }
}

@MainActor
final class AudioCapture {
    private var stream: SCStream?
    private var generation = UUID()
    private let receiver: AudioReceiver
    init(packet: @escaping @Sendable (AudioPacket) -> Void, failure: @escaping @Sendable (String) -> Void) { receiver = AudioReceiver(packet: packet, failure: failure) }
    static func requestPermissions() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw CaptureError.screenPermission }
        let authorized = await AVCaptureDevice.requestAccess(for: .audio)
        guard authorized else { throw CaptureError.microphonePermission }
    }
    func start(displayID: CGDirectDisplayID) async throws {
        await stop()
        let token = UUID(); generation = token
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayMissing }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.captureMicrophone = true
        configuration.sampleRate = 16_000; configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue)
        try stream.addStreamOutput(receiver, type: .microphone, sampleHandlerQueue: receiver.queue)
        self.stream = stream; receiver.enable(true, stream: stream)
        do {
            try await stream.startCapture()
            guard token == generation, !Task.isCancelled else { try? await stream.stopCapture(); throw CancellationError() }
        } catch {
            if self.stream === stream { receiver.enable(false); self.stream = nil }
            throw error
        }
    }
    func stop() async {
        generation = UUID(); receiver.enable(false)
        let old = stream; stream = nil
        if let old { try? await old.stopCapture() }
    }
}
