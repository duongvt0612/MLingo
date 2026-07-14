import Foundation
import Observation

@MainActor
@Observable
public final class OverlayPresentationState {
    public internal(set) var isVisible = false
    public internal(set) var isEditing = false
    public internal(set) var activeDisplayID: String?
    public internal(set) var selectedDisplay: OverlayDisplaySelection
    public internal(set) var availableDisplays: [OverlayDisplayDescriptor] = []

    public init(selectedDisplay: OverlayDisplaySelection = .automatic) {
        self.selectedDisplay = selectedDisplay
    }
}
