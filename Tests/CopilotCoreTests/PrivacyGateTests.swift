import Foundation
import Testing
@testable import CopilotCore

@Suite struct PrivacyGateTests {
    @Test func testConfirmationIsScopedToServiceModeDisplayAndVersion() {
        var gate = PrivacyGate()
        gate.markLocalPreflight(displayID: 1, passed: true)
        gate.markLocalPreflight(displayID: 2, passed: true)
        gate.confirm(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "6")
        #expect(gate.canShowPanel(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "6"))
        #expect(!(gate.canShowPanel(service: "Teams", mode: .fullDisplay, displayID: 1, version: "6")))
        #expect(!(gate.canShowPanel(service: "Zoom", mode: .window, displayID: 1, version: "6")))
        #expect(!(gate.canShowPanel(service: "Zoom", mode: .fullDisplay, displayID: 2, version: "6")))
        #expect(!(gate.canShowPanel(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "7")))
    }
    @Test func testLocalFailureInvalidatesPriorConfirmation() {
        var gate = PrivacyGate()
        gate.markLocalPreflight(displayID: 1, passed: true)
        gate.confirm(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "6")
        gate.markLocalPreflight(displayID: 1, passed: false)
        #expect(!(gate.canShowPanel(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "6")))
        gate.markLocalPreflight(displayID: 1, passed: true)
        #expect(!(gate.canShowPanel(service: "Zoom", mode: .fullDisplay, displayID: 1, version: "6")))
    }
    @Test func testNoSharingStillRequiresLocalPreflight() {
        var gate = PrivacyGate()
        #expect(!(gate.canShowPanel(service: "", mode: .none, displayID: 1, version: "")))
        gate.markLocalPreflight(displayID: 1, passed: true)
        #expect(gate.canShowPanel(service: "", mode: .none, displayID: 1, version: ""))
    }
}
