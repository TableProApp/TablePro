//
//  ToolbarSymbolsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// Both forms of each glyph are asserted here because a test run only ever takes one of them: CI
/// and every developer machine are on a release where a toolbar item has a container.
struct ToolbarSymbolsTests {
    @Test("An item in a container draws the glyph without its circle")
    func containedItemsDropTheCircle() {
        #expect(ToolbarSymbols.more(itemsHaveContainer: true) == "ellipsis")
        #expect(ToolbarSymbols.filter(isActive: false, itemsHaveContainer: true) == "line.3.horizontal.decrease")
        #expect(ToolbarSymbols.disconnect(itemsHaveContainer: true) == "xmark")
    }

    @Test("An item with no container keeps the circle")
    func bareItemsKeepTheCircle() {
        #expect(ToolbarSymbols.more(itemsHaveContainer: false) == "ellipsis.circle")
        #expect(
            ToolbarSymbols.filter(isActive: false, itemsHaveContainer: false) == "line.3.horizontal.decrease.circle"
        )
        #expect(ToolbarSymbols.disconnect(itemsHaveContainer: false) == "xmark.circle")
    }

    /// There is no filled form of the bare glyph, so the disc is the only way to say a filter is on.
    @Test("An active filter is the filled disc on both", arguments: [true, false])
    func activeFilterIsFilled(itemsHaveContainer: Bool) {
        #expect(
            ToolbarSymbols.filter(isActive: true, itemsHaveContainer: itemsHaveContainer)
                == "line.3.horizontal.decrease.circle.fill"
        )
    }

    @Test("Only a More control without a container draws the menu indicator")
    func moreIndicatorFollowsTheContainer() {
        #expect(!ToolbarSymbols.moreShowsIndicator(itemsHaveContainer: true))
        #expect(ToolbarSymbols.moreShowsIndicator(itemsHaveContainer: false))
    }

    @Test("Commit is the bare check")
    func commitIsTheBareCheck() {
        #expect(ToolbarSymbols.commit == "checkmark")
    }

    /// A name that is not a system symbol draws nothing: the toolbar item keeps an empty image and
    /// a SwiftUI label lays its icon out at zero size.
    @Test("Every name it can return is a system symbol")
    func everyNameResolves() {
        var names: Set<String> = [ToolbarSymbols.commit]
        for itemsHaveContainer in [true, false] {
            names.insert(ToolbarSymbols.more(itemsHaveContainer: itemsHaveContainer))
            names.insert(ToolbarSymbols.disconnect(itemsHaveContainer: itemsHaveContainer))
            for isActive in [true, false] {
                names.insert(ToolbarSymbols.filter(isActive: isActive, itemsHaveContainer: itemsHaveContainer))
            }
        }

        #expect(names.count == 8)
        for name in names {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not a system symbol"
            )
        }
    }
}
