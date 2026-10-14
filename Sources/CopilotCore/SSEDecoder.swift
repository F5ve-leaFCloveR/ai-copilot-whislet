import Foundation

public enum SSEEvent: Equatable, Sendable { case data(String), done }
public enum StreamDecodeError: Error, Sendable { case invalidUTF8, oversizedFrame, malformedJSON, invalidSchema, incomplete, excessiveWords, corruptMarker }

public struct SSEDecoder: Sendable {
    private var bytes = Data()
    private var fields: [String] = []
    public init() {}
    public mutating func feed(_ data: Data) throws -> [SSEEvent] {
        bytes.append(data)
        guard bytes.count <= 262_144 else { throw StreamDecodeError.oversizedFrame }
        var events: [SSEEvent] = []
        while let newline = bytes.firstIndex(of: 10) {
            var lineBytes = bytes[..<newline]
            if lineBytes.last == 13 { lineBytes = lineBytes.dropLast() }
            guard let line = String(data: lineBytes, encoding: .utf8) else { throw StreamDecodeError.invalidUTF8 }
            bytes.removeSubrange(...newline)
            if line.isEmpty {
                if !fields.isEmpty {
                    let value = fields.joined(separator: "\n")
                    events.append(value == "[DONE]" ? .done : .data(value)); fields.removeAll()
                }
            } else if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5))
                fields.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
                guard fields.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else { throw StreamDecodeError.oversizedFrame }
            }
        }
        return events
    }
}
