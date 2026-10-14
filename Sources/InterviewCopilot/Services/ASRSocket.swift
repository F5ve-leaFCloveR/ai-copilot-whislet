import Foundation
import Darwin
import CopilotCore

struct ASRMessage: Decodable, Sendable {
    let kind: String
    let sessionID: String
    let id: UUID?
    let source: AudioSource?
    let text: String?
    let endedAt: Double?
    let isFinal: Bool?
    let message: String?
    let code: String?
}

final class ASRSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let sessionID: UUID
    private let writer = DispatchQueue(label: "local.interviewcopilot.socket.write", qos: .userInitiated)
    private let reader = DispatchQueue(label: "local.interviewcopilot.socket.read", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false
    private var pending = 0
    private let onMessage: @Sendable (ASRMessage) -> Void
    private let onFailure: @Sendable (String) -> Void

    private init(descriptor: Int32, sessionID: UUID, onMessage: @escaping @Sendable (ASRMessage) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.descriptor = descriptor; self.sessionID = sessionID; self.onMessage = onMessage; self.onFailure = onFailure
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    static func connect(path: String, sessionID: UUID, onMessage: @escaping @Sendable (ASRMessage) -> Void, onFailure: @escaping @Sendable (String) -> Void) async throws -> ASRSocket {
        let bytes = Array(path.utf8) + [0]
        guard bytes.count < 104 else { throw socketError("Слишком длинный путь ASR socket") }
        for _ in 0..<150 {
            try Task.checkCancellation()
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw socketError("Не удалось создать ASR socket") }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(2 + bytes.count)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(2 + bytes.count)) }
            }
            if status == 0 {
                let connection = ASRSocket(descriptor: fd, sessionID: sessionID, onMessage: onMessage, onFailure: onFailure)
                connection.reader.async { connection.readLoop() }
                return connection
            }
            Darwin.close(fd)
            try await Task.sleep(for: .milliseconds(200))
        }
        throw socketError("ASR worker не создал socket за 30 секунд")
    }
    func send(_ packet: AudioPacket) {
        let admitted = lock.withLock { () -> Bool in
            guard !closed, pending < 8 else { return false }
            pending += 1; return true
        }
        guard admitted else { if !lock.withLock({ closed }) { onFailure("ASR не успевает обработать звук. Восстановите распознавание") }; return }
        writer.async {
            defer { self.lock.withLock { self.pending -= 1 } }
            guard !self.lock.withLock({ self.closed }) else { return }
            do {
                let payload = packet.samples.withUnsafeBytes { Data($0) }
                let header: [String: Any] = ["kind": "audio", "sessionID": self.sessionID.uuidString, "source": packet.source.rawValue, "sequence": packet.sequence, "sampleRate": 16000, "samples": packet.samples.count, "payloadBytes": payload.count, "capturedAt": packet.capturedAt]
                try self.write(header: header, payload: payload)
            } catch { self.onFailure(error.localizedDescription); self.close() }
        }
    }
    func reset() {
        writer.async {
            guard !self.lock.withLock({ self.closed }) else { return }
            try? self.write(header: ["kind": "reset", "sessionID": self.sessionID.uuidString, "samples": 0, "payloadBytes": 0, "sampleRate": 16000], payload: Data())
        }
    }
    func close() {
        let shouldClose = lock.withLock { () -> Bool in if closed { return false }; closed = true; return true }
        if shouldClose { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    }
    deinit { Darwin.close(descriptor) }
    private func write(header: [String: Any], payload: Data) throws {
        let json = try JSONSerialization.data(withJSONObject: header)
        guard json.count <= 4096, payload.count <= 32000 else { throw Self.socketError("Неверный размер ASR packet") }
        var length = UInt32(json.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(json); frame.append(payload)
        try frame.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                guard !lock.withLock({ closed }) else { throw CancellationError() }
                let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: position), bytes.count - position, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Self.socketError("Соединение с ASR worker прервано") }
                position += written
            }
        }
    }
    private func readLoop() {
        var buffer = Data(); var chunk = [UInt8](repeating: 0, count: 8192)
        while !lock.withLock({ closed }) {
            let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { if !lock.withLock({ closed }) { onFailure("ASR worker остановился. Нажмите «Восстановить»") }; close(); return }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 65536 else { onFailure("Неверный ответ ASR worker"); close(); return }
                do {
                    let message = try JSONDecoder().decode(ASRMessage.self, from: line)
                    guard message.sessionID.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame else { continue }
                    onMessage(message)
                } catch { onFailure("Не удалось прочитать ответ ASR worker"); close(); return }
            }
            if buffer.count > 65536 { onFailure("Неверный ответ ASR worker"); close(); return }
        }
    }
    private static func socketError(_ message: String) -> NSError { NSError(domain: "ASRSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
