import Foundation

enum OverlayPlacementResolver {
    private static let defaultBottomInset: CGFloat = 56

    static func placement(for frame: CGRect, in visibleFrame: CGRect) -> OverlayPlacement {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return OverlayPlacement(normalizedCenterX: 0.5, normalizedBottomY: 0)
        }
        return OverlayPlacement(
            normalizedCenterX: clamp(
                (frame.midX - visibleFrame.minX) / visibleFrame.width,
                lower: 0,
                upper: 1
            ),
            normalizedBottomY: clamp(
                (frame.minY - visibleFrame.minY) / visibleFrame.height,
                lower: 0,
                upper: 1
            )
        )
    }

    static func frame(
        for placement: OverlayPlacement?,
        panelSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGRect(origin: visibleFrame.origin, size: .zero)
        }

        let size = CGSize(
            width: min(max(panelSize.width, 0), visibleFrame.width),
            height: min(max(panelSize.height, 0), visibleFrame.height)
        )
        let centerX = normalizedValue(placement?.normalizedCenterX, fallback: 0.5)
        let defaultBottom = min(defaultBottomInset, max(visibleFrame.height - size.height, 0))
        let bottom = placement.map {
            normalizedValue($0.normalizedBottomY, fallback: 0) * visibleFrame.height
        } ?? defaultBottom
        let proposedOrigin = CGPoint(
            x: visibleFrame.minX + centerX * visibleFrame.width - size.width / 2,
            y: visibleFrame.minY + bottom
        )

        return CGRect(
            x: clamp(
                proposedOrigin.x,
                lower: visibleFrame.minX,
                upper: visibleFrame.maxX - size.width
            ),
            y: clamp(
                proposedOrigin.y,
                lower: visibleFrame.minY,
                upper: visibleFrame.maxY - size.height
            ),
            width: size.width,
            height: size.height
        )
    }

    private static func normalizedValue(_ value: Double?, fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite else { return fallback }
        return clamp(CGFloat(value), lower: 0, upper: 1)
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        min(max(value, lower), upper)
    }
}
