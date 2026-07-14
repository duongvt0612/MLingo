import AppKit
import Foundation

@MainActor
public final class FloatingSubtitleWindowController: OverlayEngineProtocol {
    typealias PanelFactory = @MainActor (CGRect) -> any OverlayPanelAdapter

    public let presentationState: OverlayPresentationState

    private let preferencesStore: any OverlayPreferencesStoreProtocol
    private let displayCatalog: any OverlayDisplayCatalogProtocol
    private let placementSaveDelay: Duration
    private let panelFactory: PanelFactory
    private var preferences: OverlayPreferences
    private var panel: (any OverlayPanelAdapter)?
    private var lastSubtitle: SubtitleItem?
    private var lastSettings = AppSettings()
    private var placementSaveTask: Task<Void, Never>?
    private var screenObserver: OverlayScreenObservation?
    private var applicationWindowScreenObserver: OverlayScreenObservation?
    private var escapeMonitor: OverlayEventMonitor?
    private var isApplyingFrame = false

    public convenience init() {
        self.init(
            preferencesStore: UserDefaultsOverlayPreferencesStore(),
            displayCatalog: AppKitOverlayDisplayCatalog(),
            placementSaveDelay: .milliseconds(250),
            observesScreenChanges: true,
            panelFactory: { AppKitOverlayPanelAdapter(frame: $0) }
        )
    }

    init(
        preferencesStore: any OverlayPreferencesStoreProtocol,
        displayCatalog: any OverlayDisplayCatalogProtocol,
        placementSaveDelay: Duration,
        observesScreenChanges: Bool,
        applicationWindowProvider: @escaping @MainActor () -> NSWindow? = {
            NSApp.mainWindow ?? NSApp.keyWindow
        },
        panelFactory: @escaping PanelFactory
    ) {
        self.preferencesStore = preferencesStore
        self.displayCatalog = displayCatalog
        self.placementSaveDelay = placementSaveDelay
        self.panelFactory = panelFactory
        let preferences = preferencesStore.load()
        self.preferences = preferences
        presentationState = OverlayPresentationState(
            selectedDisplay: preferences.selectedDisplay
        )
        refreshDisplays()

        if observesScreenChanges {
            let token = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshDisplays() }
            }
            screenObserver = OverlayScreenObservation(token: token)

            let windowToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let windowID = ObjectIdentifier(window)
                Task { @MainActor in
                    guard let applicationWindow = applicationWindowProvider(),
                          ObjectIdentifier(applicationWindow) == windowID
                    else {
                        return
                    }
                    self?.refreshDisplays()
                }
            }
            applicationWindowScreenObserver = OverlayScreenObservation(token: windowToken)
        }
    }

    public func show(settings: AppSettings) {
        lastSettings = settings
        lastSubtitle = nil
        presentationState.isEditing = false
        presentationState.isVisible = true
        refreshDisplays()
        ensurePanel()
        panel?.ignoresMouseEvents = true
        removeEscapeMonitor()
        renderAndResize()
        panel?.orderFront()
    }

    public func update(with subtitle: SubtitleItem, settings: AppSettings) {
        lastSubtitle = subtitle
        lastSettings = settings
        ensurePanel()
        renderAndResize()
        if presentationState.isVisible {
            panel?.orderFront()
        }
    }

    public func hide() {
        flushPendingPlacementSave()
        lastSubtitle = nil
        presentationState.isEditing = false
        presentationState.isVisible = false
        panel?.ignoresMouseEvents = true
        removeEscapeMonitor()
        renderAndResize()
        panel?.orderOut()
    }

    public func setVisible(_ isVisible: Bool) {
        if isVisible {
            ensurePanel()
            presentationState.isVisible = true
            renderAndResize()
            panel?.orderFront()
        } else {
            endRepositioning()
            presentationState.isVisible = false
            panel?.orderOut()
        }
    }

    public func beginRepositioning() {
        ensurePanel()
        presentationState.isVisible = true
        presentationState.isEditing = true
        panel?.ignoresMouseEvents = false
        installEscapeMonitor()
        renderAndResize()
        panel?.orderFront()
    }

    public func endRepositioning() {
        guard presentationState.isEditing else { return }
        flushPendingPlacementSave()
        presentationState.isEditing = false
        panel?.ignoresMouseEvents = true
        removeEscapeMonitor()
        renderAndResize()
    }

    public func resetPosition() {
        guard let displayID = presentationState.activeDisplayID else { return }
        flushPendingPlacementSave()
        preferences.placementsByDisplayID[displayID] = nil
        preferencesStore.save(preferences)
        renderAndResize()
    }

    public func selectDisplay(_ selection: OverlayDisplaySelection) {
        flushPendingPlacementSave()
        preferences.selectedDisplay = selection
        preferencesStore.save(preferences)
        presentationState.selectedDisplay = selection
        refreshDisplays()
    }

    func refreshDisplays() {
        let displays = displayCatalog.currentDisplays()
        presentationState.availableDisplays = displays
        presentationState.selectedDisplay = preferences.selectedDisplay
        let display = OverlayDisplayResolver.resolve(
            selection: preferences.selectedDisplay,
            displays: displays,
            appWindowDisplayID: displayCatalog.currentAppWindowDisplayID()
        )
        presentationState.activeDisplayID = display?.id
        if panel != nil {
            renderAndResize()
        }
    }

    private func ensurePanel() {
        guard panel == nil, let display = activeDisplay else { return }
        let initialSize = CGSize(
            width: min(display.visibleFrame.width * 0.82, 980),
            height: min(180, display.visibleFrame.height * 0.4)
        )
        let initialFrame = OverlayPlacementResolver.frame(
            for: preferences.placementsByDisplayID[display.id],
            panelSize: initialSize,
            in: display.visibleFrame
        )
        let panel = panelFactory(initialFrame)
        panel.ignoresMouseEvents = !presentationState.isEditing
        panel.onMove = { [weak self] frame in
            self?.panelDidMove(to: frame)
        }
        self.panel = panel
    }

    private var activeDisplay: OverlayDisplayDescriptor? {
        guard let activeDisplayID = presentationState.activeDisplayID else { return nil }
        return presentationState.availableDisplays.first(where: { $0.id == activeDisplayID })
    }

    private func renderAndResize() {
        guard let panel, let display = activeDisplay else { return }
        panel.render(
            OverlayPanelContent(
                subtitle: lastSubtitle,
                settings: lastSettings,
                isEditing: presentationState.isEditing,
                displays: presentationState.availableDisplays,
                selectedDisplay: presentationState.selectedDisplay,
                onDone: { [weak self] in self?.endRepositioning() },
                onResetPosition: { [weak self] in self?.resetPosition() },
                onSelectDisplay: { [weak self] selection in self?.selectDisplay(selection) }
            )
        )

        let maximumSize = CGSize(
            width: min(display.visibleFrame.width * 0.82, 980),
            height: display.visibleFrame.height * 0.4
        )
        let fittingSize = panel.sizeThatFits(maximumSize)
        let size = CGSize(
            width: min(max(fittingSize.width, min(320, maximumSize.width)), maximumSize.width),
            height: min(max(fittingSize.height, 1), maximumSize.height)
        )
        let frame = OverlayPlacementResolver.frame(
            for: preferences.placementsByDisplayID[display.id],
            panelSize: size,
            in: display.visibleFrame
        )

        isApplyingFrame = true
        panel.setFrame(frame)
        isApplyingFrame = false
    }

    private func panelDidMove(to frame: CGRect) {
        guard presentationState.isEditing,
              !isApplyingFrame,
              let display = activeDisplay
        else {
            return
        }
        preferences.placementsByDisplayID[display.id] = OverlayPlacementResolver.placement(
            for: frame,
            in: display.visibleFrame
        )
        placementSaveTask?.cancel()
        let preferencesStore = preferencesStore
        let preferences = preferences
        let delay = placementSaveDelay
        placementSaveTask = Task {
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            preferencesStore.save(preferences)
        }
    }

    private func flushPendingPlacementSave() {
        guard placementSaveTask != nil else { return }
        placementSaveTask?.cancel()
        placementSaveTask = nil
        preferencesStore.save(preferences)
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endRepositioning()
            return nil
        }
        if let token {
            escapeMonitor = OverlayEventMonitor(token: token)
        }
    }

    private func removeEscapeMonitor() {
        guard escapeMonitor != nil else { return }
        self.escapeMonitor = nil
    }
}

private final class OverlayScreenObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

private final class OverlayEventMonitor: @unchecked Sendable {
    private let token: Any

    init(token: Any) {
        self.token = token
    }

    deinit {
        NSEvent.removeMonitor(token)
    }
}
