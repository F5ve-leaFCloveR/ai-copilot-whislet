import Foundation

public struct ContentGuard: Sendable {
    private static let markers = ["</final>", "<|im_start|>", "<|im_end|>", "$_['assistant}"]
    private var pending = ""
    public private(set) var isCorrupt = false
    public private(set) var acceptedText = ""
    public init() {}
    public mutating func accept(_ chunk: String) -> Bool {
        acceptedText = ""
        guard !isCorrupt else { return false }
        let text = pending + chunk
        pending = ""
        if Self.markers.contains(where: { text.contains($0) }) { isCorrupt = true; return false }
        var withheld = 0
        for marker in Self.markers {
            for count in 1..<marker.count where text.hasSuffix(String(marker.prefix(count))) { withheld = max(withheld, count) }
        }
        acceptedText = String(text.dropLast(withheld)); pending = String(text.suffix(withheld))
        return !acceptedText.isEmpty
    }
    public mutating func finish() throws -> String {
        guard !isCorrupt, pending.count < 3 else { throw StreamDecodeError.corruptMarker }
        let tail = pending; pending = ""; acceptedText = tail; return tail
    }
}
