import SwiftUI

public struct SubtitleOverlayView: View {
    private let subtitle: SubtitleItem?
    private let settings: AppSettings

    public init(subtitle: SubtitleItem?, settings: AppSettings) {
        self.subtitle = subtitle
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 8) {
            if settings.showBilingualSubtitles, let original = subtitle?.original {
                Text(original)
                    .font(.system(size: max(settings.subtitleFontSize * 0.58, 14), weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
            }

            Text(subtitle?.translated ?? "MLingo")
                .font(.system(size: settings.subtitleFontSize, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(settings.subtitleTextOpacity))
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                .accessibilityLabel(subtitle?.translated ?? "MLingo subtitle overlay")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(settings.subtitleBackgroundOpacity))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .padding(24)
    }
}
