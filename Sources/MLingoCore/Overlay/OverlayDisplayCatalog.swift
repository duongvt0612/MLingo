import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol OverlayDisplayCatalogProtocol: AnyObject {
    func currentDisplays() -> [OverlayDisplayDescriptor]
    func currentAppWindowDisplayID() -> String?
}

@MainActor
final class AppKitOverlayDisplayCatalog: OverlayDisplayCatalogProtocol {
    func currentDisplays() -> [OverlayDisplayDescriptor] {
        let screens = NSScreen.screens
        return screens.compactMap { screen in
            guard let id = Self.stableID(for: screen) else { return nil }
            return OverlayDisplayDescriptor(
                id: id,
                name: screen.localizedName,
                visibleFrame: screen.visibleFrame,
                isMain: screen == screens.first
            )
        }
    }

    func currentAppWindowDisplayID() -> String? {
        let screen = NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen
        return screen.flatMap(Self.stableID(for:))
    }

    private static func stableID(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
