import Foundation

public enum BudgetError: Error, LocalizedError, Sendable {
    case invalidReservation, duplicateRequest, sessionLimit, keyLimit
    public var errorDescription: String? {
        switch self {
        case .invalidReservation: "Некорректный резерв стоимости"
        case .duplicateRequest: "Запрос уже учтён"
        case .sessionLimit: "Достигнут лимит сессии"
        case .keyLimit: "Недостаточно доступного бюджета ключа"
        }
    }
}

public struct BudgetLedger: Sendable {
    public let limitRub: Decimal
    public private(set) var spentRub: Decimal = 0
    public private(set) var keyRemainingRub: Decimal?
    private var reservations: [UUID: Decimal] = [:]
    private var settled: Set<UUID> = []
    private var requestsSinceBalance = 0
    private var lastBalanceAt: Date?
    public var reservedRub: Decimal { reservations.values.reduce(0, +) }
    public init(limitRub: Decimal = 50) { self.limitRub = max(0, limitRub) }
    public mutating func authorize(id: UUID, reserveRub: Decimal = 1) throws {
        guard reserveRub > 0 else { throw BudgetError.invalidReservation }
        guard reservations[id] == nil, !settled.contains(id) else { throw BudgetError.duplicateRequest }
        guard spentRub + reservedRub + reserveRub <= limitRub else { throw BudgetError.sessionLimit }
        if let remaining = keyRemainingRub, reservedRub + reserveRub > remaining { throw BudgetError.keyLimit }
        reservations[id] = reserveRub; requestsSinceBalance += 1
    }
    public mutating func settle(id: UUID, actualRub: Decimal?) {
        guard reservations[id] != nil, let actual = actualRub, actual >= 0 else { return }
        reservations.removeValue(forKey: id); settled.insert(id); spentRub += actual
        if let remaining = keyRemainingRub { keyRemainingRub = max(0, remaining - actual) }
    }
    public func validateReservation(id: UUID) throws {
        guard reservations[id] != nil else { throw BudgetError.invalidReservation }
        guard spentRub + reservedRub <= limitRub else { throw BudgetError.sessionLimit }
        if let remaining = keyRemainingRub, reservedRub > remaining { throw BudgetError.keyLimit }
    }
    public mutating func observeKeyRemaining(_ rub: Decimal, at: Date = Date()) {
        keyRemainingRub = max(0, rub); requestsSinceBalance = 0; lastBalanceAt = at
    }
    public func shouldPollBalance(at: Date = Date()) -> Bool {
        guard let previous = lastBalanceAt else { return true }
        return requestsSinceBalance >= 5 || at.timeIntervalSince(previous) >= 300
    }
}
