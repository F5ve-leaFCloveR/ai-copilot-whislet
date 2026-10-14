import Foundation
import Testing
@testable import CopilotCore

@Suite struct BudgetTests {
    @Test func refreshedBalanceCanBlockAnExistingReservation() throws {
        var ledger = BudgetLedger()
        ledger.observeKeyRemaining(10)
        let id = UUID()
        try ledger.authorize(id: id)
        ledger.observeKeyRemaining(0)
        #expect(throws: BudgetError.keyLimit) { try ledger.validateReservation(id: id) }
        ledger.observeKeyRemaining(1)
        try ledger.validateReservation(id: id)
    }
    @Test func pollingIsBoundedByRequestsAndElapsedTime() throws {
        var ledger = BudgetLedger()
        let date = Date(timeIntervalSince1970: 100)
        #expect(ledger.shouldPollBalance(at: date))
        ledger.observeKeyRemaining(100, at: date)
        #expect(!ledger.shouldPollBalance(at: date.addingTimeInterval(299)))
        #expect(ledger.shouldPollBalance(at: date.addingTimeInterval(300)))
        for _ in 0..<4 { try ledger.authorize(id: UUID()) }
        #expect(!ledger.shouldPollBalance(at: date))
        try ledger.authorize(id: UUID())
        #expect(ledger.shouldPollBalance(at: date))
    }
    @Test func testKeyBudgetResetDoesNotResetSessionSpend() throws {
        var ledger = BudgetLedger(limitRub: 50)
        let id = UUID()
        try ledger.authorize(id: id, reserveRub: 1)
        ledger.settle(id: id, actualRub: Decimal(string: "0.12"))
        ledger.observeKeyRemaining(10_000)
        #expect(ledger.spentRub == Decimal(string: "0.12"))
        #expect(ledger.reservedRub == 0)
    }
    @Test func testMissingUsageKeepsReservationAndPreventsOverspend() throws {
        var ledger = BudgetLedger(limitRub: 1)
        let id = UUID()
        try ledger.authorize(id: id, reserveRub: 1)
        ledger.settle(id: id, actualRub: nil)
        #expect(ledger.reservedRub == 1)
        #expect(throws: (any Error).self) { try ledger.authorize(id: UUID(), reserveRub: 1) }
    }
    @Test func testSettlementIsChargedOnceAndKeyRemainingIsRespected() throws {
        var ledger = BudgetLedger(limitRub: 50)
        ledger.observeKeyRemaining(1)
        let id = UUID()
        try ledger.authorize(id: id, reserveRub: 1)
        ledger.settle(id: id, actualRub: Decimal(string: "0.8"))
        ledger.settle(id: id, actualRub: Decimal(string: "0.8"))
        #expect(ledger.spentRub == Decimal(string: "0.8"))
        #expect(throws: (any Error).self) { try ledger.authorize(id: UUID(), reserveRub: 1) }
    }
}
