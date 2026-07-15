import SwiftUI

public struct SubtitleOverlayView: View {
    private let subtitle: SubtitleItem?
    private let settings: AppSettings
    private let isEditing: Bool
    private let displays: [OverlayDisplayDescriptor]
    private let selectedDisplay: OverlayDisplaySelection
    private let onDone: () -> Void
    private let onResetPosition: () -> Void
    private let onSelectDisplay: (OverlayDisplaySelection) -> Void

    public init(subtitle: SubtitleItem?, settings: AppSettings) {
        self.subtitle = subtitle
        self.settings = settings
        isEditing = false
        displays = []
        selectedDisplay = .automatic
        onDone = {}
        onResetPosition = {}
        onSelectDisplay = { _ in }
    }

    @MainActor
    init(content: OverlayPanelContent) {
        subtitle = content.subtitle
        settings = content.settings
        isEditing = content.isEditing
        displays = content.displays
        selectedDisplay = content.selectedDisplay
        onDone = content.onDone
        onResetPosition = content.onResetPosition
        onSelectDisplay = content.onSelectDisplay
    }

    public var body: some View {
        VStack(spacing: 8) {
            if isEditing {
                editHUD
            }
            subtitleCard
        }
        .padding(24)
    }

    private var subtitleCard: some View {
        VStack(spacing: 8) {
            if settings.showBilingualSubtitles, let original = subtitle?.original {
                Text(original)
                    .font(.system(size: max(settings.subtitleFontSize * 0.58, 14), weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
            }

            Text(subtitle?.translated ?? "MLingo")
                .font(.system(size: settings.subtitleFontSize, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(settings.subtitleTextOpacity))
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.7), radius: 1, x: 1, y: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(settings.subtitleBackgroundOpacity))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isEditing ? Color.cyan.opacity(0.9) : .white.opacity(0.18),
                    lineWidth: isEditing ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var editHUD: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundStyle(.cyan)
                .accessibilityHidden(true)

            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)

            Button("Reset Position", action: onResetPosition)

            Menu("Display") {
                displayButton("Automatic", selection: .automatic)
                if !displays.isEmpty {
                    Divider()
                }
                ForEach(displays) { display in
                    displayButton(
                        display.name,
                        selection: .display(id: display.id)
                    )
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reposition subtitle overlay")
    }

    @ViewBuilder
    private func displayButton(
        _ title: String,
        selection: OverlayDisplaySelection
    ) -> some View {
        Button {
            onSelectDisplay(selection)
        } label: {
            if selectedDisplay == selection {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var accessibilityText: String {
        guard let subtitle else { return "MLingo subtitle overlay" }
        if settings.showBilingualSubtitles {
            return "Original: \(subtitle.original). Translation: \(subtitle.translated)"
        }
        return subtitle.translated
    }
}
