import CoreGraphics

enum ERDiagramScrollAction: Equatable {
    case pan(CGPoint)
    case zoom(CGFloat)
}

enum ERDiagramScrollTranslator {
    static func action(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        isZoomModifierActive: Bool,
        currentOffset: CGPoint,
        currentMagnification: CGFloat
    ) -> ERDiagramScrollAction {
        if isZoomModifierActive {
            return .zoom(currentMagnification + scrollingDeltaY * 0.01)
        }
        let multiplier: CGFloat = hasPreciseScrollingDeltas ? 1.0 : 10.0
        return .pan(CGPoint(
            x: currentOffset.x + scrollingDeltaX * multiplier,
            y: currentOffset.y + scrollingDeltaY * multiplier
        ))
    }
}
