import AppKit

enum UIWindowKind: String, CaseIterable {
    case toolbar, answer, quickSettings, settings, context, history, setup
}

@MainActor
final class ProtectedWindowRegistry {
    var canShow: (UIWindowKind) -> Bool = { _ in false }
    private var entries: [ObjectIdentifier: (NSWindow, UIWindowKind)] = [:]

    var windows: [NSWindow] { entries.values.map(\.0) }
    var registeredKinds: [UIWindowKind] { entries.values.map(\.1) }

    func register(_ window: NSWindow, kind: UIWindowKind) {
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        entries[ObjectIdentifier(window)] = (window, kind)
    }

    @discardableResult
    func show(_ window: NSWindow, activate: Bool = false) -> Bool {
        guard let (_, kind) = entries[ObjectIdentifier(window)], canShow(kind) else {
            window.orderOut(nil)
            return false
        }
        window.sharingType = .none
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        return true
    }

    func hideAll() { windows.forEach { $0.orderOut(nil) } }

    func closeAuxiliary() {
        for (window, kind) in entries.values where kind != .toolbar && kind != .answer {
            window.orderOut(nil)
        }
    }

    func closeAll() { windows.forEach { $0.orderOut(nil) } }

    func contains(_ window: NSWindow) -> Bool { entries[ObjectIdentifier(window)] != nil }
    func kind(of window: NSWindow) -> UIWindowKind? { entries[ObjectIdentifier(window)]?.1 }
}
