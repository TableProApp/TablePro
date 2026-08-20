//
//  PopoverPresenterTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// `NSPopover` decides where to put itself from its content size at `show` time, and an
/// `NSHostingController` publishes nothing by default, so AppKit used to place every popover for a
/// 320x320 box it invented and then resize the window from the origin it had already chosen. The
/// popover walked up and left off its own anchor. These assert the size is known before anything is
/// presented, since that is the only input the placement has.
@Suite("Popover presenter publishes its content size before showing")
@MainActor
struct PopoverPresenterTests {
    private struct FixedContent: View {
        var body: some View {
            Color.clear.frame(width: 180, height: 240)
        }
    }

    /// Stands in for the JSON and hex editors, whose content has no size of its own and takes
    /// whatever it is given.
    private struct FlexibleContent: View {
        var body: some View {
            ScrollView {
                VStack {
                    ForEach(0 ..< 40, id: \.self) { Text(verbatim: "row \($0)") }
                }
            }
        }
    }

    @Test("Content that sizes itself reaches the popover at that size")
    func selfSizingContentPublishesItsOwnSize() throws {
        let popover = PopoverPresenter.make { _ in FixedContent() }
        let controller = try #require(popover.contentViewController)

        #expect(controller.preferredContentSize == NSSize(width: 180, height: 240))
    }

    @Test("A caller's content size reaches the popover even when the content does not size itself")
    func requestedSizeSurvivesFlexibleContent() throws {
        let requested = NSSize(width: 420, height: 300)
        let popover = PopoverPresenter.make(contentSize: requested) { _ in FlexibleContent() }
        let controller = try #require(popover.contentViewController)

        #expect(controller.preferredContentSize == requested)
    }

    @Test("Flexible content with no requested size still publishes a size rather than nothing")
    func flexibleContentNeverPublishesZero() throws {
        let popover = PopoverPresenter.make { _ in FlexibleContent() }
        let controller = try #require(popover.contentViewController)

        #expect(controller.preferredContentSize != .zero)
    }

    @Test("The behaviour the caller asked for is the behaviour the popover gets")
    func behaviourIsForwarded() {
        let popover = PopoverPresenter.make(behavior: .applicationDefined) { _ in FixedContent() }

        #expect(popover.behavior == .applicationDefined)
    }
}
