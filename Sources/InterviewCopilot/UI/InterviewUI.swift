import AppKit
import SwiftUI

@MainActor
class ProtectedPanel: NSPanel {
    let registry: ProtectedWindowRegistry
    var acceptsKeyboard = true
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(registry: ProtectedWindowRegistry, kind: UIWindowKind, frame: NSRect, resizable: Bool) {
        self.registry = registry
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        registry.register(self, kind: kind)
    }

    @discardableResult
    func showWithoutActivation() -> Bool { registry.show(self) }
}

@MainActor
final class ToolbarPanel: ProtectedPanel {
    init(registry: ProtectedWindowRegistry, frame: NSRect) {
        super.init(registry: registry, kind: .toolbar, frame: frame, resizable: false)
        acceptsKeyboard = false
    }
}

@MainActor
final class AnswerPanel: ProtectedPanel {
    init(registry: ProtectedWindowRegistry, frame: NSRect) {
        super.init(registry: registry, kind: .answer, frame: frame, resizable: true)
        minSize = NSSize(width: 480, height: 280)
        isMovableByWindowBackground = false
    }
}

@MainActor
final class QuickSettingsPanel: ProtectedPanel {
    init(registry: ProtectedWindowRegistry, frame: NSRect) {
        super.init(registry: registry, kind: .quickSettings, frame: frame, resizable: false)
        isMovableByWindowBackground = false
    }
}

@MainActor
final class ProtectedEditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    init(registry: ProtectedWindowRegistry, kind: UIWindowKind, frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        registry.register(self, kind: kind)
    }
}

@MainActor
final class InterviewUI: NSObject, NSWindowDelegate {
    let model: UIModel
    let registry: ProtectedWindowRegistry
    let toolbar: ToolbarPanel
    let answer: AnswerPanel
    let quickSettings: QuickSettingsPanel
    let settings: ProtectedEditorWindow
    let context: ProtectedEditorWindow
    let history: ProtectedEditorWindow
    let setup: ProtectedEditorWindow
    var answerOffset: NSPoint { NSPoint(x: (toolbar.frame.width - answer.frame.width) / 2, y: -answer.frame.height - 12) }
    private var movingGroup = false

    init(model: UIModel, registry: ProtectedWindowRegistry) {
        self.model = model
        self.registry = registry
        let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bar = NSRect(x: bounds.midX - 219, y: bounds.maxY - 80, width: 438, height: 40)
        let reply = NSRect(x: bar.midX - 340, y: bar.minY - 472, width: 680, height: 460)
        toolbar = ToolbarPanel(registry: registry, frame: bar)
        answer = AnswerPanel(registry: registry, frame: reply)
        quickSettings = QuickSettingsPanel(registry: registry, frame: NSRect(x: bar.maxX + 12, y: bar.maxY - 500, width: 320, height: 500))
        settings = ProtectedEditorWindow(registry: registry, kind: .settings, frame: NSRect(x: bounds.midX - 400, y: bounds.midY - 300, width: 800, height: 600))
        context = ProtectedEditorWindow(registry: registry, kind: .context, frame: NSRect(x: bounds.midX - 320, y: bounds.midY - 250, width: 640, height: 500))
        history = ProtectedEditorWindow(registry: registry, kind: .history, frame: NSRect(x: bounds.midX - 320, y: bounds.midY - 230, width: 640, height: 460))
        setup = ProtectedEditorWindow(registry: registry, kind: .setup, frame: NSRect(x: bounds.midX - 340, y: bounds.midY - 320, width: 680, height: 640))
        super.init()
        settings.minSize = NSSize(width: 700, height: 500)
        context.minSize = NSSize(width: 480, height: 380)
        history.minSize = NSSize(width: 400, height: 280)
        setup.minSize = NSSize(width: 590, height: 500)
        registry.windows.forEach { $0.delegate = self }
        toolbar.contentView = NSHostingView(rootView: ToolbarSurface(model: model, menu: { [weak self] in self?.toggleQuickSettings() }))
        answer.contentView = NSHostingView(rootView: AnswerSurface(model: model, close: { [weak self] in self?.closeAnswer() }))
        quickSettings.contentView = NSHostingView(rootView: QuickSettingsSurface(model: model, close: { [weak self] in self?.quickSettings.orderOut(nil) }))
        settings.contentView = NSHostingView(rootView: SettingsSurface(model: model, close: { [weak self] in self?.settings.orderOut(nil) }))
        context.contentView = NSHostingView(rootView: ProfileSurface(model: model, close: { [weak self] in self?.context.orderOut(nil) }))
        history.contentView = NSHostingView(rootView: HistorySurface(model: model, close: { [weak self] in self?.history.orderOut(nil) }, select: { [weak self] id in
            guard let self else { return }; self.model.send(.selectHistory(id)); self.history.orderOut(nil); self.showAnswer()
        }))
        setup.contentView = NSHostingView(rootView: SetupSurface(model: model, close: { [weak self] in self?.setup.orderOut(nil) }, settings: { [weak self] in self?.showSettings() }))
        applySavedLayout()
        prepareAllWindows()
    }

    func prepareAllWindows() { registry.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() } }
    func refresh() { model.refresh() }

    func writePreview(to url: URL) throws {
        let windows: [NSWindow] = [toolbar, answer, quickSettings].filter(\.isVisible)
        guard !windows.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let union = windows.dropFirst().reduce(windows[0].frame) { $0.union($1.frame) }
        let size = NSSize(width: union.width + 48, height: union.height + 48)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: 2, y: 2)
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for window in windows {
            guard let view = window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let captured = image.cgImage else { continue }
            let target = NSRect(x: window.frame.minX - union.minX + 24, y: window.frame.minY - union.minY + 24, width: window.frame.width, height: window.frame.height)
            let radius: CGFloat = window === answer ? 18 : window === toolbar ? 12 : 10
            let border = CGPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil)
            let content = CGPath(roundedRect: target.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil)
            graphics.cgContext.saveGState()
            graphics.cgContext.addPath(content)
            graphics.cgContext.clip()
            graphics.cgContext.setBlendMode(.normal)
            graphics.cgContext.draw(captured, in: target)
            graphics.cgContext.restoreGState()
            graphics.cgContext.addPath(border)
            graphics.cgContext.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
            graphics.cgContext.setLineWidth(1)
            graphics.cgContext.strokePath()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    func showToolbar() -> Bool {
        constrainToolbar()
        return toolbar.showWithoutActivation()
    }

    @discardableResult
    func showAnswer() -> Bool {
        guard showToolbar(), registry.canShow(.answer) else { return false }
        movingGroup = true
        alignAnswer()
        if answer.parent !== toolbar { answer.parent?.removeChildWindow(answer); toolbar.addChildWindow(answer, ordered: .below) }
        movingGroup = false
        return answer.showWithoutActivation()
    }

    func closeAnswer() { toolbar.removeChildWindow(answer); answer.orderOut(nil) }

    func toggleQuickSettings() {
        if quickSettings.isVisible { quickSettings.orderOut(nil); return }
        guard registry.canShow(.quickSettings) else { return }
        let bounds = screenBounds(for: toolbar.frame), bar = toolbar.frame
        var frame = NSRect(x: bar.maxX + 12, y: bar.maxY - 500, width: 320, height: 500)
        if frame.maxX > bounds.maxX { frame.origin.x = bar.minX - 332 }
        if frame.minX < bounds.minX { frame.origin = NSPoint(x: bar.midX - 160, y: bar.minY - 512) }
        quickSettings.setFrame(constrained(frame, on: bounds), display: false)
        registry.show(quickSettings)
    }

    func showSetup() { constrainIndependent(setup); registry.show(setup, activate: true) }
    func showSettings(section: String = "Общие") {
        settings.contentView = NSHostingView(rootView: SettingsSurface(model: model, close: { [weak self] in self?.settings.orderOut(nil) }, section: section))
        constrainIndependent(settings); registry.show(settings, activate: true)
        quickSettings.orderOut(nil)
    }
    func showContext() { constrainIndependent(context); registry.show(context, activate: true); quickSettings.orderOut(nil) }
    func showHistory() { model.send(.pinHistory); constrainIndependent(history); registry.show(history, activate: true); quickSettings.orderOut(nil) }
    func hideAll() { closeAnswer(); registry.hideAll() }
    func stop() { closeAnswer(); registry.closeAll() }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !movingGroup else { return }
        movingGroup = true
        defer { movingGroup = false }
        if window === toolbar {
            quickSettings.orderOut(nil)
            constrainToolbar()
            if answer.isVisible { alignAnswer() }
            publishLayout()
        } else if window === answer {
            guard !answer.inLiveResize else { return }
            let expected = NSPoint(x: toolbar.frame.minX + answerOffset.x, y: toolbar.frame.minY + answerOffset.y)
            let delta = NSPoint(x: answer.frame.minX - expected.x, y: answer.frame.minY - expected.y)
            toolbar.setFrameOrigin(NSPoint(x: toolbar.frame.minX + delta.x, y: toolbar.frame.minY + delta.y))
            quickSettings.orderOut(nil)
            alignAnswer()
            publishLayout()
        } else {
            constrainIndependent(window)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !movingGroup else { return }
        movingGroup = true
        defer { movingGroup = false }
        if window === answer {
            alignAnswer()
            quickSettings.orderOut(nil)
            publishLayout()
        } else {
            constrainIndependent(window)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { windowDidResize(notification) }

    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === answer { closeAnswer() } else { sender.orderOut(nil) }; return false }

    private func publishLayout() {
        let value = UIWindowLayout(toolbarX: toolbar.frame.minX, toolbarY: toolbar.frame.minY, answerOffsetX: answerOffset.x, answerOffsetY: answerOffset.y, answerWidth: answer.frame.width, answerHeight: answer.frame.height)
        model.settings.layout = value
        model.send(.windowLayout(value))
    }

    private func applySavedLayout() {
        guard let layout = model.settings.layout else { return }
        movingGroup = true
        toolbar.setFrameOrigin(NSPoint(x: layout.toolbarX, y: layout.toolbarY))
        answer.setContentSize(NSSize(width: max(480, layout.answerWidth), height: max(280, layout.answerHeight)))
        constrainToolbar()
        movingGroup = false
    }

    private func alignAnswer() {
        let bounds = screenBounds(for: toolbar.frame)
        let size = NSSize(width: min(answer.frame.width, bounds.width), height: min(answer.frame.height, max(280, bounds.height - toolbar.frame.height - 12)))
        if answer.frame.size != size { answer.setContentSize(size) }
        constrainToolbar(includeAnswer: true)
        answer.setFrameOrigin(NSPoint(x: toolbar.frame.minX + answerOffset.x, y: toolbar.frame.minY + answerOffset.y))
    }

    private func constrainToolbar(includeAnswer: Bool = false) {
        let bounds = screenBounds(for: toolbar.frame)
        var target = constrained(toolbar.frame, on: bounds)
        if answer.isVisible || includeAnswer {
            let child = NSRect(origin: NSPoint(x: target.minX + answerOffset.x, y: target.minY + answerOffset.y), size: answer.frame.size)
            let union = target.union(child)
            if union.width <= bounds.width {
                if union.minX < bounds.minX { target.origin.x += bounds.minX - union.minX }
                if union.maxX > bounds.maxX { target.origin.x -= union.maxX - bounds.maxX }
            }
            if union.height <= bounds.height {
                if union.minY < bounds.minY { target.origin.y += bounds.minY - union.minY }
                if union.maxY > bounds.maxY { target.origin.y -= union.maxY - bounds.maxY }
            }
        }
        if toolbar.frame.origin != target.origin { toolbar.setFrameOrigin(target.origin) }
    }

    private func constrainIndependent(_ window: NSWindow) { window.setFrame(constrained(window.frame, on: screenBounds(for: window.frame)), display: false) }
    private func screenBounds(for frame: NSRect) -> NSRect { NSScreen.screens.max { a, b in a.visibleFrame.intersection(frame).area < b.visibleFrame.intersection(frame).area }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }
    private func constrained(_ frame: NSRect, on bounds: NSRect) -> NSRect { var result = frame; result.size.width = min(result.width, bounds.width); result.size.height = min(result.height, bounds.height); result.origin.x = max(bounds.minX, min(result.minX, bounds.maxX - result.width)); result.origin.y = max(bounds.minY, min(result.minY, bounds.maxY - result.height)); return result }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) } }
