import CoreGraphics
import Foundation

nonisolated enum DuoWidthClass: Equatable, Sendable {
    case compact
    case regular
}

nonisolated struct DuoLayoutContext: Equatable, Sendable {
    let size: CGSize
    let widthClass: DuoWidthClass
    let showsResult: Bool

    init(size: CGSize, widthClass: DuoWidthClass, showsResult: Bool = false) {
        self.size = size
        self.widthClass = widthClass
        self.showsResult = showsResult
    }
}

nonisolated struct DuoLayoutPlan: Equatable, Sendable {
    let previewFieldCount: Int
    let editorMaxHeight: CGFloat
    let revealsDetailAlongsideList: Bool

    static let compactDefault = DuoLayoutPlan(
        previewFieldCount: DuoLayoutResolver.compactPreviewFieldCount,
        editorMaxHeight: DuoLayoutResolver.compactEditorHeightWithoutResult,
        revealsDetailAlongsideList: false
    )
}

nonisolated enum DuoLayoutResolver {
    static let compactPreviewFieldCount = 4
    static let regularPreviewFieldCount = 8
    static let compactEditorHeightWithResult: CGFloat = 120
    static let compactEditorHeightWithoutResult: CGFloat = 250
    static let minimumEditorHeight: CGFloat = 120
    static let maximumEditorHeight: CGFloat = 640

    static func plan(for context: DuoLayoutContext) -> DuoLayoutPlan {
        DuoLayoutPlan(
            previewFieldCount: previewFieldCount(for: context.widthClass),
            editorMaxHeight: editorMaxHeight(for: context),
            revealsDetailAlongsideList: context.widthClass == .regular
        )
    }

    static func previewFieldCount(for widthClass: DuoWidthClass) -> Int {
        switch widthClass {
        case .compact: return compactPreviewFieldCount
        case .regular: return regularPreviewFieldCount
        }
    }

    static func editorMaxHeight(for context: DuoLayoutContext) -> CGFloat {
        guard context.widthClass == .regular else {
            return context.showsResult ? compactEditorHeightWithResult : compactEditorHeightWithoutResult
        }
        let height = context.size.height
        guard height.isFinite, height > 0 else {
            return context.showsResult ? compactEditorHeightWithResult : compactEditorHeightWithoutResult
        }
        let fraction: CGFloat = context.showsResult ? 0.38 : 0.6
        return min(max(height * fraction, minimumEditorHeight), maximumEditorHeight)
    }
}
