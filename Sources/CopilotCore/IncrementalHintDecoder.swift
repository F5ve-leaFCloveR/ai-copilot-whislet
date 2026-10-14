import Foundation

public struct IncrementalHintDecoder: Sendable {
    private enum Phase: Sendable { case opening, keyStart, key, colon, array, valueStart, value, valueEnd, fieldEnd, done }
    private enum Field: String, Sendable { case points, followups }
    private var phase: Phase = .opening
    private var field: Field?
    private var fields: Set<Field> = []
    private var allowsEmptyArray = false
    private var completed: [String] = []
    public private(set) var followups: [String] = []
    private var string = ""
    private var escaped = false
    private var unicodeDigits: String?
    private var highSurrogate: UInt32?
    private var byteCount = 0
    private let requireFollowups: Bool
    public init(requireFollowups: Bool = false) { self.requireFollowups = requireFollowups }
    public mutating func feed(_ chunk: String) throws -> [String] {
        byteCount += chunk.utf8.count
        guard byteCount <= 65_536 else { throw StreamDecodeError.oversizedFrame }
        for scalar in chunk.unicodeScalars {
            if phase == .key || phase == .value {
                if try consumeString(scalar) {
                    if phase == .key {
                        guard let next = Field(rawValue: string), fields.insert(next).inserted else { throw StreamDecodeError.invalidSchema }
                        field = next
                        phase = .colon
                    } else {
                        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StreamDecodeError.invalidSchema }
                        if field == .points { completed.append(string) }
                        else {
                            guard string.split(whereSeparator: \.isWhitespace).count <= 12 else { throw StreamDecodeError.excessiveWords }
                            followups.append(string)
                        }
                        phase = .valueEnd
                    }
                    string = ""
                }
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch phase {
            case .opening: guard scalar == "{" else { throw StreamDecodeError.malformedJSON }; phase = .keyStart
            case .keyStart: guard scalar == "\"" else { throw StreamDecodeError.invalidSchema }; phase = .key
            case .colon: guard scalar == ":" else { throw StreamDecodeError.malformedJSON }; phase = .array
            case .array:
                guard scalar == "[" else { throw StreamDecodeError.invalidSchema }
                allowsEmptyArray = true
                phase = .valueStart
            case .valueStart:
                if scalar == "]", allowsEmptyArray, field == .followups { phase = .fieldEnd }
                else {
                    guard scalar == "\"", valueCount < 3 else { throw StreamDecodeError.invalidSchema }
                    phase = .value
                }
                allowsEmptyArray = false
            case .valueEnd:
                if scalar == "," {
                    guard valueCount < 3 else { throw StreamDecodeError.invalidSchema }
                    phase = .valueStart
                }
                else if scalar == "]" { phase = .fieldEnd }
                else { throw StreamDecodeError.malformedJSON }
            case .fieldEnd:
                if scalar == "," { phase = .keyStart }
                else if scalar == "}" { phase = .done }
                else { throw StreamDecodeError.invalidSchema }
            case .done: throw StreamDecodeError.malformedJSON
            case .key, .value: break
            }
        }
        return completed + (phase == .value && field == .points ? [string] : [])
    }
    public func finish() throws -> [String] {
        guard phase == .done, fields.contains(.points), (!requireFollowups || fields.contains(.followups)), (1...3).contains(completed.count) else { throw StreamDecodeError.incomplete }
        for point in completed where point.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            _ = try Self.codeSource(in: point)
        }
        if let first = completed.first, first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            let source = try Self.codeSource(in: first)
            guard source.components(separatedBy: "\n").count <= 160,
                  source.split(whereSeparator: \.isWhitespace).count <= 800,
                  completed.dropFirst().joined(separator: " ").split(whereSeparator: \.isWhitespace).count <= 120 else { throw StreamDecodeError.excessiveWords }
        } else {
            guard completed.joined(separator: " ").split(whereSeparator: \.isWhitespace).count <= 240 else { throw StreamDecodeError.excessiveWords }
        }
        return completed
    }
    private static func codeSource(in point: String) throws -> String {
        let value = point.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openingEnd = value.firstIndex(of: "\n"), value.hasSuffix("\n```"),
              value.distance(from: openingEnd, to: value.endIndex) > 4 else { throw StreamDecodeError.incomplete }
        let source = String(value[value.index(after: openingEnd)..<value.index(value.endIndex, offsetBy: -4)])
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StreamDecodeError.incomplete }
        return source
    }
    private var valueCount: Int { field == .points ? completed.count : followups.count }
    private mutating func consumeString(_ scalar: UnicodeScalar) throws -> Bool {
        if var digits = unicodeDigits {
            guard "0123456789abcdefABCDEF".unicodeScalars.contains(scalar) else { throw StreamDecodeError.malformedJSON }
            digits.unicodeScalars.append(scalar)
            if digits.count < 4 { unicodeDigits = digits; return false }
            unicodeDigits = nil
            guard let unit = UInt32(digits, radix: 16) else { throw StreamDecodeError.malformedJSON }
            if let high = highSurrogate {
                guard (0xDC00...0xDFFF).contains(unit), let value = UnicodeScalar(0x10000 + ((high - 0xD800) << 10) + unit - 0xDC00) else { throw StreamDecodeError.malformedJSON }
                string.unicodeScalars.append(value); highSurrogate = nil
            } else if (0xD800...0xDBFF).contains(unit) { highSurrogate = unit }
            else {
                guard !(0xDC00...0xDFFF).contains(unit), let value = UnicodeScalar(unit) else { throw StreamDecodeError.malformedJSON }
                string.unicodeScalars.append(value)
            }
            return false
        }
        if escaped {
            escaped = false
            if scalar == "u" { unicodeDigits = ""; return false }
            guard highSurrogate == nil else { throw StreamDecodeError.malformedJSON }
            let values: [UnicodeScalar: UnicodeScalar] = ["\"":"\"", "\\":"\\", "/":"/", "b":"\u{8}", "f":"\u{c}", "n":"\n", "r":"\r", "t":"\t"]
            guard let value = values[scalar] else { throw StreamDecodeError.malformedJSON }
            string.unicodeScalars.append(value); return false
        }
        if scalar == "\\" { escaped = true; return false }
        guard highSurrogate == nil else { throw StreamDecodeError.malformedJSON }
        if scalar == "\"" { return true }
        guard scalar.value >= 32 else { throw StreamDecodeError.malformedJSON }
        string.unicodeScalars.append(scalar); return false
    }
}
