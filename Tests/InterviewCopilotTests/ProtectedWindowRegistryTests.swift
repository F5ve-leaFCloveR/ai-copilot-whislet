import AppKit
import Testing
@testable import InterviewCopilot

@Suite(.serialized)
@MainActor
struct ProtectedWindowRegistryTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 24, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        return window
    }

    @Test func unregisteredWindowCannotBeShownEvenWhenGateAllows() {
        let window = window(); defer { window.close() }
        let registry = ProtectedWindowRegistry(); registry.canShow = { _ in true }
        #expect(!registry.contains(window))
        #expect(!registry.show(window))
        #expect(!window.isVisible)
    }

    @Test func allSevenProductWindowsAreRegisteredAndProtectedBeforeDisplay() {
        _ = NSApplication.shared
        let registry = ProtectedWindowRegistry()
        let ui = InterviewUI(model: UIModel(), registry: registry)
        defer { registry.closeAll(); registry.windows.forEach { $0.close() } }
        #expect(registry.windows.count == 7)
        #expect(Set(registry.registeredKinds) == Set(UIWindowKind.allCases))
        let productWindows: [NSWindow] = [ui.toolbar, ui.answer, ui.quickSettings, ui.settings, ui.context, ui.history, ui.setup]
        #expect(productWindows.allSatisfy { registry.contains($0) })
        #expect(productWindows.allSatisfy { $0.sharingType == .none && !$0.isVisible })
        for window in productWindows {
            #expect(!registry.show(window))
            #expect(!window.isVisible)
        }
    }

    @Test func revokedGateHidesAlreadyVisibleWindowAndShowRestoresProtection() {
        let window = window(); defer { window.close() }
        let registry = ProtectedWindowRegistry()
        registry.register(window, kind: .answer)
        registry.canShow = { _ in true }
        window.sharingType = .readOnly
        #expect(registry.show(window))
        #expect(window.isVisible)
        #expect(window.sharingType == .none)
        registry.canShow = { _ in false }
        #expect(!registry.show(window))
        #expect(!window.isVisible)
    }
}
