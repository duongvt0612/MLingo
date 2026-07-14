import Foundation
import Testing
@testable import MLingoCore

@Test
func overlayPreferencesRoundTripAndMalformedDataFallsBack() throws {
    let suiteName = "MLingoOverlayTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsOverlayPreferencesStore(
        defaults: defaults,
        key: "overlay-preferences"
    )
    let expected = OverlayPreferences(
        selectedDisplay: .display(id: "display-2"),
        placementsByDisplayID: [
            "display-2": OverlayPlacement(
                normalizedCenterX: 0.72,
                normalizedBottomY: 0.18
            )
        ]
    )

    store.save(expected)
    #expect(store.load() == expected)

    defaults.set(Data("not-json".utf8), forKey: "overlay-preferences")
    #expect(store.load() == OverlayPreferences())
}

@Test
func overlayDisplayResolverUsesPinnedDisplayAndFallsBackToAutomatic() throws {
    let main = OverlayDisplayDescriptor(
        id: "main",
        name: "Built-in Display",
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        isMain: true
    )
    let external = OverlayDisplayDescriptor(
        id: "external",
        name: "Studio Display",
        visibleFrame: CGRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
        isMain: false
    )
    let displays = [main, external]

    #expect(
        OverlayDisplayResolver.resolve(
            selection: .display(id: external.id),
            displays: displays,
            appWindowDisplayID: main.id
        ) == external
    )
    #expect(
        OverlayDisplayResolver.resolve(
            selection: .automatic,
            displays: displays,
            appWindowDisplayID: external.id
        ) == external
    )
    #expect(
        OverlayDisplayResolver.resolve(
            selection: .display(id: "disconnected"),
            displays: displays,
            appWindowDisplayID: main.id
        ) == main
    )
}

@Test
func overlayPlacementRoundTripsAcrossVisibleFrameChanges() {
    let originalVisibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 800)
    let originalFrame = CGRect(x: 550, y: 210, width: 300, height: 160)
    let placement = OverlayPlacementResolver.placement(
        for: originalFrame,
        in: originalVisibleFrame
    )

    #expect(abs(placement.normalizedCenterX - 0.6) < 0.0001)
    #expect(abs(placement.normalizedBottomY - 0.2) < 0.0001)

    let resizedVisibleFrame = CGRect(x: -200, y: 20, width: 2_000, height: 1_000)
    let resolved = OverlayPlacementResolver.frame(
        for: placement,
        panelSize: CGSize(width: 500, height: 240),
        in: resizedVisibleFrame
    )

    #expect(abs(resolved.midX - 1_000) < 0.0001)
    #expect(abs(resolved.minY - 220) < 0.0001)
}

@Test
func overlayPlacementDefaultsToBottomCenterAndClampsOffscreenValues() {
    let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 800)
    let panelSize = CGSize(width: 400, height: 200)

    let defaultFrame = OverlayPlacementResolver.frame(
        for: nil,
        panelSize: panelSize,
        in: visibleFrame
    )
    #expect(defaultFrame.midX == visibleFrame.midX)
    #expect(defaultFrame.minY == visibleFrame.minY + 56)

    let clamped = OverlayPlacementResolver.frame(
        for: OverlayPlacement(normalizedCenterX: 2, normalizedBottomY: -1),
        panelSize: panelSize,
        in: visibleFrame
    )
    #expect(clamped.maxX == visibleFrame.maxX)
    #expect(clamped.minY == visibleFrame.minY)
}
