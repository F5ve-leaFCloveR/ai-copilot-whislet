import Foundation

public struct PrivacyConfirmation: Codable, Equatable, Sendable {
    public let service: String
    public let mode: ShareMode
    public let displayID: UInt32
    public let version: String
    public let checkedAt: Date
    public init(service: String, mode: ShareMode, displayID: UInt32, version: String, checkedAt: Date = Date()) {
        self.service = service; self.mode = mode; self.displayID = displayID; self.version = version; self.checkedAt = checkedAt
    }
}

public struct PrivacyGate: Sendable {
    public private(set) var confirmations: [PrivacyConfirmation]
    private var localResults: [UInt32: Bool] = [:]
    public init(confirmations: [PrivacyConfirmation] = []) { self.confirmations = confirmations }
    public mutating func markLocalPreflight(displayID: UInt32, passed: Bool) {
        localResults[displayID] = passed
        if !passed { confirmations.removeAll { $0.displayID == displayID } }
    }
    public mutating func confirm(service: String, mode: ShareMode, displayID: UInt32, version: String, at: Date = Date()) {
        confirmations.removeAll { $0.service == service && $0.mode == mode && $0.displayID == displayID && $0.version == version }
        confirmations.append(PrivacyConfirmation(service: service, mode: mode, displayID: displayID, version: version, checkedAt: at))
    }
    public func canShowPanel(service: String, mode: ShareMode, displayID: UInt32, version: String) -> Bool {
        guard localResults[displayID] == true else { return false }
        if mode == .none { return true }
        return confirmations.contains { $0.service == service && $0.mode == mode && $0.displayID == displayID && $0.version == version }
    }
}
