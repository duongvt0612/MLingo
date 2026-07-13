import AppKit
import SwiftUI

@MainActor
public final class FloatingSubtitleWindowController: OverlayEngineProtocol {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<SubtitleOverlayView>?
    private var lastSubtitle: SubtitleItem?
    private var lastSettings = AppSettings()

    public init() {}

    public func show() {
        if panel == nil {
            makePanel()
        }

        render()
        panel?.orderFrontRegardless()
    }

    public func update(with subtitle: SubtitleItem, settings: AppSettings) {
        lastSubtitle = subtitle
        lastSettings = settings
        render()
        panel?.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(screenFrame.width * 0.72, 980), height: 180)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 56
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        let host = NSHostingController(rootView: SubtitleOverlayView(subtitle: nil, settings: lastSettings))
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view

        self.panel = panel
        self.hostingController = host
    }

    private func render() {
        if panel == nil {
            makePanel()
        }

        hostingController?.rootView = SubtitleOverlayView(subtitle: lastSubtitle, settings: lastSettings)
    }
}
