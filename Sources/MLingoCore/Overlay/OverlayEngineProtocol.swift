import Foundation

@MainActor
public protocol OverlayEngineProtocol: AnyObject, Sendable {
    var presentationState: OverlayPresentationState { get }

    func show(settings: AppSettings)
    func update(with subtitle: SubtitleItem, settings: AppSettings)
    func hide()
    func setVisible(_ isVisible: Bool)
    func beginRepositioning()
    func endRepositioning()
    func resetPosition()
    func selectDisplay(_ selection: OverlayDisplaySelection)
}
