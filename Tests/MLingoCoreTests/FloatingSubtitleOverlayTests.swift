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

@Test @MainActor
func floatingOverlayReusesPanelAndHiddenUpdatesStayHidden() throws {
    let store = TestOverlayPreferencesStore()
    let catalog = TestOverlayDisplayCatalog(displays: [testMainDisplay])
    var panels: [TestOverlayPanel] = []
    let controller = FloatingSubtitleWindowController(
        preferencesStore: store,
        displayCatalog: catalog,
        placementSaveDelay: .zero,
        observesScreenChanges: false,
        panelFactory: { frame in
            let panel = TestOverlayPanel(frame: frame)
            panels.append(panel)
            return panel
        }
    )

    controller.show(settings: AppSettings())
    let panel = try #require(panels.first)
    #expect(panels.count == 1)
    #expect(panel.isVisible)
    #expect(panel.ignoresMouseEvents)
    #expect(panel.content?.subtitle == nil)

    let first = testSubtitle(translated: "First")
    controller.update(with: first, settings: AppSettings())
    #expect(panel.content?.subtitle == first)

    controller.setVisible(false)
    controller.update(with: testSubtitle(translated: "Hidden update"), settings: AppSettings())
    #expect(!panel.isVisible)
    #expect(!controller.presentationState.isVisible)

    controller.show(settings: AppSettings())
    #expect(panels.count == 1)
    #expect(panel.content?.subtitle == nil)
    #expect(panel.isVisible)
}

@Test @MainActor
func floatingOverlayEditModeControlsMouseAndHud() throws {
    let panel = TestOverlayPanel(frame: .zero)
    let controller = FloatingSubtitleWindowController(
        preferencesStore: TestOverlayPreferencesStore(),
        displayCatalog: TestOverlayDisplayCatalog(displays: [testMainDisplay]),
        placementSaveDelay: .zero,
        observesScreenChanges: false,
        panelFactory: { frame in
            panel.frame = frame
            return panel
        }
    )

    controller.show(settings: AppSettings())
    controller.beginRepositioning()
    #expect(controller.presentationState.isEditing)
    #expect(controller.presentationState.isVisible)
    #expect(!panel.ignoresMouseEvents)
    #expect(panel.content?.isEditing == true)

    panel.content?.onDone()
    #expect(!controller.presentationState.isEditing)
    #expect(panel.ignoresMouseEvents)

    controller.beginRepositioning()
    controller.setVisible(false)
    #expect(!controller.presentationState.isEditing)
    #expect(!panel.isVisible)
    #expect(panel.ignoresMouseEvents)
}

@Test @MainActor
func floatingOverlayPersistsDisplayAndRecoversAfterDisconnect() throws {
    let external = OverlayDisplayDescriptor(
        id: "external",
        name: "Studio Display",
        visibleFrame: CGRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
        isMain: false
    )
    let store = TestOverlayPreferencesStore(
        preferences: OverlayPreferences(selectedDisplay: .display(id: external.id))
    )
    let catalog = TestOverlayDisplayCatalog(
        displays: [testMainDisplay, external],
        appWindowDisplayID: testMainDisplay.id
    )
    let panel = TestOverlayPanel(frame: .zero)
    let controller = FloatingSubtitleWindowController(
        preferencesStore: store,
        displayCatalog: catalog,
        placementSaveDelay: .zero,
        observesScreenChanges: false,
        panelFactory: { frame in
            panel.frame = frame
            return panel
        }
    )

    controller.show(settings: AppSettings())
    #expect(controller.presentationState.activeDisplayID == external.id)

    catalog.displays = [testMainDisplay]
    controller.refreshDisplays()
    #expect(controller.presentationState.activeDisplayID == testMainDisplay.id)
    #expect(controller.presentationState.selectedDisplay == .display(id: external.id))
    #expect(store.preferences.selectedDisplay == .display(id: external.id))

    catalog.displays = [testMainDisplay, external]
    controller.refreshDisplays()
    #expect(controller.presentationState.activeDisplayID == external.id)

    controller.selectDisplay(.automatic)
    #expect(controller.presentationState.activeDisplayID == testMainDisplay.id)
    #expect(store.preferences.selectedDisplay == .automatic)
}

@Test @MainActor
func floatingOverlayPersistsDraggedPlacementAndResetReturnsToDefault() async throws {
    let store = TestOverlayPreferencesStore()
    let panel = TestOverlayPanel(frame: .zero)
    let controller = FloatingSubtitleWindowController(
        preferencesStore: store,
        displayCatalog: TestOverlayDisplayCatalog(displays: [testMainDisplay]),
        placementSaveDelay: .zero,
        observesScreenChanges: false,
        panelFactory: { frame in
            panel.frame = frame
            return panel
        }
    )

    controller.show(settings: AppSettings())
    controller.beginRepositioning()
    panel.simulateMove(
        to: CGRect(x: 620, y: 240, width: panel.frame.width, height: panel.frame.height)
    )
    try await Task.sleep(for: .milliseconds(10))

    let saved = try #require(store.preferences.placementsByDisplayID[testMainDisplay.id])
    #expect(saved.normalizedCenterX > 0.5)
    #expect(saved.normalizedBottomY > 0)

    controller.resetPosition()
    #expect(store.preferences.placementsByDisplayID[testMainDisplay.id] == nil)
    #expect(panel.frame.midX == testMainDisplay.visibleFrame.midX)
    #expect(panel.frame.minY == testMainDisplay.visibleFrame.minY + 56)
}

@Test @MainActor
func floatingOverlayDoesNotLetDebouncedMoveOverwriteDisplaySelection() async throws {
    let external = OverlayDisplayDescriptor(
        id: "external",
        name: "Studio Display",
        visibleFrame: CGRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
        isMain: false
    )
    let store = TestOverlayPreferencesStore()
    let panel = TestOverlayPanel(frame: .zero)
    let controller = FloatingSubtitleWindowController(
        preferencesStore: store,
        displayCatalog: TestOverlayDisplayCatalog(displays: [testMainDisplay, external]),
        placementSaveDelay: .milliseconds(50),
        observesScreenChanges: false,
        panelFactory: { frame in
            panel.frame = frame
            return panel
        }
    )

    controller.show(settings: AppSettings())
    controller.beginRepositioning()
    panel.simulateMove(
        to: CGRect(x: 620, y: 240, width: panel.frame.width, height: panel.frame.height)
    )
    controller.selectDisplay(.display(id: external.id))
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.preferences.selectedDisplay == .display(id: external.id))
    #expect(store.preferences.placementsByDisplayID[testMainDisplay.id] != nil)
}

@Test @MainActor
func floatingOverlayResizesUpwardAndClampsToVisibleFrame() {
    let panel = TestOverlayPanel(frame: .zero)
    panel.fittingSize = CGSize(width: 1_400, height: 700)
    let controller = FloatingSubtitleWindowController(
        preferencesStore: TestOverlayPreferencesStore(),
        displayCatalog: TestOverlayDisplayCatalog(displays: [testMainDisplay]),
        placementSaveDelay: .zero,
        observesScreenChanges: false,
        panelFactory: { frame in
            panel.frame = frame
            return panel
        }
    )

    controller.show(settings: AppSettings())
    #expect(panel.frame.width == 980)
    #expect(panel.frame.height == testMainDisplay.visibleFrame.height * 0.4)
    #expect(panel.frame.minY == testMainDisplay.visibleFrame.minY + 56)
    #expect(testMainDisplay.visibleFrame.contains(panel.frame))

    panel.fittingSize = CGSize(width: 600, height: 120)
    controller.update(with: testSubtitle(translated: "Short"), settings: AppSettings())

    #expect(panel.frame.size == panel.fittingSize)
    #expect(panel.frame.minY == testMainDisplay.visibleFrame.minY + 56)
    #expect(testMainDisplay.visibleFrame.contains(panel.frame))
}

private let testMainDisplay = OverlayDisplayDescriptor(
    id: "main",
    name: "Built-in Display",
    visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
    isMain: true
)

private func testSubtitle(translated: String) -> SubtitleItem {
    SubtitleItem(
        original: "Original",
        translated: translated,
        start: 0,
        end: 1
    )
}

private final class TestOverlayPreferencesStore: OverlayPreferencesStoreProtocol,
    @unchecked Sendable
{
    var preferences: OverlayPreferences

    init(preferences: OverlayPreferences = OverlayPreferences()) {
        self.preferences = preferences
    }

    func load() -> OverlayPreferences { preferences }
    func save(_ preferences: OverlayPreferences) { self.preferences = preferences }
}

@MainActor
private final class TestOverlayDisplayCatalog: OverlayDisplayCatalogProtocol {
    var displays: [OverlayDisplayDescriptor]
    var appWindowDisplayID: String?

    init(
        displays: [OverlayDisplayDescriptor],
        appWindowDisplayID: String? = "main"
    ) {
        self.displays = displays
        self.appWindowDisplayID = appWindowDisplayID
    }

    func currentDisplays() -> [OverlayDisplayDescriptor] { displays }
    func currentAppWindowDisplayID() -> String? { appWindowDisplayID }
}

@MainActor
private final class TestOverlayPanel: OverlayPanelAdapter {
    var frame: CGRect
    var isVisible = false
    var ignoresMouseEvents = true
    var onMove: ((CGRect) -> Void)?
    var content: OverlayPanelContent?
    var fittingSize = CGSize(width: 720, height: 160)

    init(frame: CGRect) {
        self.frame = frame
    }

    func render(_ content: OverlayPanelContent) {
        self.content = content
    }

    func sizeThatFits(_ maximumSize: CGSize) -> CGSize {
        CGSize(
            width: min(fittingSize.width, maximumSize.width),
            height: min(fittingSize.height, maximumSize.height)
        )
    }

    func setFrame(_ frame: CGRect) {
        self.frame = frame
    }

    func orderFront() { isVisible = true }
    func orderOut() { isVisible = false }

    func simulateMove(to frame: CGRect) {
        self.frame = frame
        onMove?(frame)
    }
}
