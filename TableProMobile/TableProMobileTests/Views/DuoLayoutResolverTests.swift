import CoreGraphics
@testable import TableProMobile
import Testing

@Suite("Duo layout resolver")
struct DuoLayoutResolverTests {
    private static let outerDisplay = CGSize(width: 466, height: 678)
    private static let innerDisplay = CGSize(width: 669, height: 951)
    private static let innerDisplayLandscape = CGSize(width: 951, height: 669)

    @Test("A compact width keeps the four field previews the phone layout was built for")
    func compactPreviewBudgetIsUnchanged() {
        #expect(DuoLayoutResolver.previewFieldCount(for: .compact) == 4)
    }

    @Test("A regular width spends its extra room on more fields")
    func regularPreviewBudgetIsLarger() {
        let compact = DuoLayoutResolver.previewFieldCount(for: .compact)
        let regular = DuoLayoutResolver.previewFieldCount(for: .regular)
        #expect(regular > compact)
    }

    @Test("Every preview budget leaves at least a title pair and one detail row")
    func previewBudgetIsUsable() {
        for widthClass in [DuoWidthClass.compact, .regular] {
            #expect(DuoLayoutResolver.previewFieldCount(for: widthClass) >= 2)
        }
    }

    @Test("A compact width keeps the editor heights the phone layout shipped with")
    func compactEditorHeightIsUnchanged() {
        let withResult = DuoLayoutContext(size: Self.outerDisplay, widthClass: .compact, showsResult: true)
        let withoutResult = DuoLayoutContext(size: Self.outerDisplay, widthClass: .compact, showsResult: false)

        #expect(DuoLayoutResolver.editorMaxHeight(for: withResult) == 120)
        #expect(DuoLayoutResolver.editorMaxHeight(for: withoutResult) == 250)
    }

    @Test("A regular width gives the editor more room than the compact phone height")
    func regularEditorHeightGrows() {
        let context = DuoLayoutContext(size: Self.innerDisplay, widthClass: .regular, showsResult: true)
        #expect(DuoLayoutResolver.editorMaxHeight(for: context) > 120)
    }

    @Test("An editor with no result to show is taller than one sharing the screen")
    func editorShrinksForAResult() {
        let withResult = DuoLayoutContext(size: Self.innerDisplay, widthClass: .regular, showsResult: true)
        let withoutResult = DuoLayoutContext(size: Self.innerDisplay, widthClass: .regular, showsResult: false)

        #expect(
            DuoLayoutResolver.editorMaxHeight(for: withoutResult)
                > DuoLayoutResolver.editorMaxHeight(for: withResult)
        )
    }

    @Test("The editor never takes so much of a short container that the result is squeezed out")
    func editorLeavesRoomForTheResult() {
        for size in [Self.outerDisplay, Self.innerDisplay, Self.innerDisplayLandscape] {
            let context = DuoLayoutContext(size: size, widthClass: .regular, showsResult: true)
            let height = DuoLayoutResolver.editorMaxHeight(for: context)
            #expect(height <= size.height / 2)
        }
    }

    @Test("A container that has not been measured yet falls back to the compact heights")
    func unmeasuredContainerFallsBack() {
        let zero = DuoLayoutContext(size: .zero, widthClass: .regular, showsResult: true)
        let infinite = DuoLayoutContext(
            size: CGSize(width: 100, height: CGFloat.infinity),
            widthClass: .regular,
            showsResult: true
        )

        #expect(DuoLayoutResolver.editorMaxHeight(for: zero) == 120)
        #expect(DuoLayoutResolver.editorMaxHeight(for: infinite) == 120)
    }

    @Test("Only a regular width reveals a detail beside the list")
    func detailRevealFollowsWidth() {
        let compact = DuoLayoutContext(size: Self.outerDisplay, widthClass: .compact)
        let regular = DuoLayoutContext(size: Self.innerDisplay, widthClass: .regular)

        #expect(DuoLayoutResolver.plan(for: compact).revealsDetailAlongsideList == false)
        #expect(DuoLayoutResolver.plan(for: regular).revealsDetailAlongsideList)
    }

    @Test("A plan carries the same answers the individual resolvers give")
    func planAgreesWithItsParts() {
        let context = DuoLayoutContext(size: Self.innerDisplay, widthClass: .regular, showsResult: true)
        let plan = DuoLayoutResolver.plan(for: context)

        #expect(plan.previewFieldCount == DuoLayoutResolver.previewFieldCount(for: .regular))
        #expect(plan.editorMaxHeight == DuoLayoutResolver.editorMaxHeight(for: context))
    }
}
