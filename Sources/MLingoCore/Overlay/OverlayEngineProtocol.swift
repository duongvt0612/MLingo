import Foundation

@MainActor
public protocol OverlayEngineProtocol: AnyObject, Sendable {
    func show()
    func update(with subtitle: SubtitleItem, settings: AppSettings)
    func hide()
}
