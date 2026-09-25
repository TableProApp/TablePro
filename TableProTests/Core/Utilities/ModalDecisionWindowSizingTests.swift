//
//  ModalDecisionWindowSizingTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct ModalDecisionWindowSizingTests {
    private let available = NSSize(width: 1_440, height: 900)
    private let decisionStyleMask: NSWindow.StyleMask = [.titled, .closable]

    /// The value a greedy SwiftUI root actually answered with in #2930. It is finite, so an
    /// `isFinite` guard passes it straight through to a window that then raises.
    private let greedyHeight = CGFloat.greatestFiniteMagnitude

    private func fittedSize(of rootView: some View, proposedWidth: CGFloat, within bounds: NSSize) -> NSSize {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        return host.sizeThatFits(in: ModalDecisionWindowSizing.proposal(width: proposedWidth, within: bounds))
    }

    private func greedyRoot() -> some View {
        VStack(spacing: 0) {
            Text(verbatim: "header")
            Form {
                Section { Text(verbatim: "row") }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: - The clamp

    @Test("greatestFiniteMagnitude is bounded to the available height, not accepted as finite")
    func greedyHeightIsBounded() {
        let size = ModalDecisionWindowSizing.contentSize(
            fitting: NSSize(width: 520, height: greedyHeight),
            within: available
        )
        #expect(size.height == available.height)
        #expect(size.width == 520)
    }

    @Test("A size that already fits is returned unchanged")
    func fittingSizeIsUntouched() {
        let size = ModalDecisionWindowSizing.contentSize(
            fitting: NSSize(width: 560, height: 460),
            within: available
        )
        #expect(size == NSSize(width: 560, height: 460))
    }

    @Test("A size larger than the screen is brought back inside it")
    func oversizedIsClamped() {
        let size = ModalDecisionWindowSizing.contentSize(
            fitting: NSSize(width: 4_000, height: 3_000),
            within: available
        )
        #expect(size == available)
    }

    @Test("NaN and non-positive dimensions fall back to the available size")
    func degenerateDimensionsFallBack() {
        let nan = ModalDecisionWindowSizing.contentSize(
            fitting: NSSize(width: CGFloat.nan, height: CGFloat.nan),
            within: available
        )
        #expect(nan == available)

        let zero = ModalDecisionWindowSizing.contentSize(fitting: .zero, within: available)
        #expect(zero == available)

        let infinite = ModalDecisionWindowSizing.contentSize(
            fitting: NSSize(width: 520, height: CGFloat.infinity),
            within: available
        )
        #expect(infinite.height == available.height)
    }

    @Test("A window with no screen still gets a usable bound")
    func availableSizeHasAFallback() {
        let size = ModalDecisionWindowSizing.availableSize(for: nil)
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(size.height.isFinite)
    }

    // MARK: - The roots that go through it

    /// Without the bounded proposal this measures `greatestFiniteMagnitude`, which is what
    /// `NSWindow` raised on.
    @Test("A greedy root cannot produce a height a window would refuse")
    func greedyRootIsBounded() {
        let fitted = fittedSize(of: greedyRoot(), proposedWidth: 520, within: available)
        let size = ModalDecisionWindowSizing.contentSize(fitting: fitted, within: available)
        #expect(size.height <= available.height)
        #expect(size.height < CGFloat(Int32.max))
    }

    private func pairingSheet(clientName: String = "Raycast") throws -> PairingApprovalSheet {
        let redirect = try #require(URL(string: "http://127.0.0.1:51888/callback"))
        return PairingApprovalSheet(
            request: PairingRequest(
                clientName: clientName,
                challenge: "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY",
                redirectURL: redirect,
                requestedScopes: nil,
                requestedConnectionIds: nil
            ),
            codeExpiresAt: Date(timeIntervalSinceNow: 300),
            onComplete: { _ in }
        )
    }

    private func unboundedHeight(of rootView: some View) -> CGFloat {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        return host.sizeThatFits(in: NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// The regression itself: measured with nothing to bound it, the sheet used to answer
    /// `CGFloat.greatestFiniteMagnitude`.
    @Test("The pairing approval sheet is not greedy, even measured without a bound")
    func pairingSheetIsNotGreedy() throws {
        let height = try unboundedHeight(of: pairingSheet())
        #expect(height.isFinite)
        #expect(height < CGFloat(Int32.max))
        #expect(height < available.height)
    }

    @Test("The pairing approval sheet measures the same bounded and unbounded")
    func pairingSheetMeasuresConsistently() throws {
        let sheet = try pairingSheet()
        let bounded = fittedSize(of: sheet, proposedWidth: 520, within: available)
        #expect(bounded.width == 520)
        #expect(bounded.height == unboundedHeight(of: sheet))
        #expect(ModalDecisionWindowSizing.contentSize(fitting: bounded, within: available) == bounded)
    }

    /// The name is attacker-supplied, so it must not be able to stretch the sheet off the screen.
    @Test("A very long client name does not grow the sheet past the screen")
    func longClientNameStaysBounded() throws {
        let long = String(repeating: "Raycast on macbook-pro ", count: 200)
        let height = try unboundedHeight(of: pairingSheet(clientName: long))
        #expect(height.isFinite)
        #expect(height < available.height)
    }

    /// The other caller of the same presentation path. Its root is fixed in both axes, so the
    /// bounded proposal and the clamp must both be no-ops for it.
    @Test("A root that is fixed in both axes is unaffected by the bound")
    func fixedRootIsUnaffected() {
        let fixed = Text(verbatim: "statement").frame(width: 560, height: 460)
        let fitted = fittedSize(of: fixed, proposedWidth: 560, within: available)
        #expect(fitted == NSSize(width: 560, height: 460))
        #expect(ModalDecisionWindowSizing.contentSize(fitting: fitted, within: available) == fitted)
    }

    // MARK: - The frame that reaches the window

    @Test("The content budget leaves room for the window's own chrome")
    func contentBudgetSubtractsChrome() {
        let budget = ModalDecisionWindowSizing.contentBudget(within: available, styleMask: decisionStyleMask)
        #expect(budget.height < available.height)
        #expect(budget.width == available.width)
    }

    /// The raise in #2930 happened in `NSWindow.init(contentViewController:)`, on a frame outside
    /// `CGRect(INT_MIN, INT_MIN, INT_MAX - INT_MIN, INT_MAX - INT_MIN)`. Budgeting for the chrome is
    /// what makes the whole window fit, not just its content. The window is never closed: closing
    /// one in-process takes the test host down with it.
    @Test("A window built from the clamped size fits the screen it was measured against")
    func clampedWindowFitsAvailableFrame() {
        let budget = ModalDecisionWindowSizing.contentBudget(within: available, styleMask: decisionStyleMask)
        let host = NSHostingController(rootView: greedyRoot())
        host.sizingOptions = []
        let fitted = host.sizeThatFits(in: ModalDecisionWindowSizing.proposal(width: 520, within: budget))
        host.view.frame = NSRect(
            origin: .zero,
            size: ModalDecisionWindowSizing.contentSize(fitting: fitted, within: budget)
        )
        let window = ModalDecisionWindow(contentViewController: host)
        window.styleMask = decisionStyleMask
        #expect(window.frame.height.isFinite)
        #expect(window.frame.height <= available.height)
        #expect(window.frame.width <= available.width)
    }

    /// A decision the user has not answered is not somewhere to hang the next one.
    @Test("A decision window is never resolved as a sheet parent")
    func decisionWindowIsNotAParent() {
        let host = NSHostingController(rootView: Text(verbatim: "decision").frame(width: 200, height: 200))
        host.sizingOptions = []
        let window = ModalDecisionWindow(contentViewController: host)
        window.styleMask = decisionStyleMask
        #expect(window.styleMask.contains(.titled))
        #expect(AlertHelper.isContentWindow(window) == false)
    }
}
