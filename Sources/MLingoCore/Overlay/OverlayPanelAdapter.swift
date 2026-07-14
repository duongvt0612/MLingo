import AppKit
import SwiftUI

@MainActor
struct OverlayPanelContent {
    let subtitle: SubtitleItem?
    let settings: AppSettings
    let isEditing: Bool
    let displays: [OverlayDisplayDescriptor]
    let selectedDisplay: OverlayDisplaySelection
    let onDone: () -> Void
    let onResetPosition: () -> Void
    let onSelectDisplay: (OverlayDisplaySelection) -> Void
}

@MainActor
protocol OverlayPanelAdapter: AnyObject {
    var frame: CGRect { get }
    var isVisible: Bool { get }
    var ignoresMouseEvents: Bool { get set }
    var onMove: ((CGRect) -> Void)? { get set }

    func render(_ content: OverlayPanelContent)
    func sizeThatFits(_ maximumSize: CGSize) -> CGSize
    func setFrame(_ frame: CGRect)
    func orderFront()
    func orderOut()
}

@MainActor
final class AppKitOverlayPanelAdapter: NSObject, OverlayPanelAdapter, NSWindowDelegate {
    private let panel: NSPanel
    private let hostingController: NSHostingController<SubtitleOverlayView>
    var onMove: ((CGRect) -> Void)?

    var frame: CGRect { panel.frame }
    var isVisible: Bool { panel.isVisible }
    var ignoresMouseEvents: Bool {
        get { panel.ignoresMouseEvents }
        set { panel.ignoresMouseEvents = newValue }
    }

    init(frame: CGRect) {
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingController = NSHostingController(
            rootView: SubtitleOverlayView(subtitle: nil, settings: AppSettings())
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        hostingController.view.frame = CGRect(origin: .zero, size: frame.size)
        hostingController.view.autoresizingMask = [.width, .height]
        panel.contentView = hostingController.view
    }

    func render(_ content: OverlayPanelContent) {
        hostingController.rootView = SubtitleOverlayView(content: content)
        hostingController.view.layoutSubtreeIfNeeded()
    }

    func sizeThatFits(_ maximumSize: CGSize) -> CGSize {
        hostingController.sizeThatFits(in: maximumSize)
    }

    func setFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: false)
    }

    func orderFront() {
        panel.orderFrontRegardless()
    }

    func orderOut() {
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        onMove?(panel.frame)
    }
}
