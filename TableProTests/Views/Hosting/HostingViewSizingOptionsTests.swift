//
//  HostingViewSizingOptionsTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

/// `NSHostingView.sizingOptions` defaults to `.standardBounds`, which measures three sizes on every
/// layout pass and publishes them to the enclosing AppKit view. A host its container sizes states `[]`.
struct HostingViewSizingOptionsTests {
    @Test("The theme chrome's hosting cell states its sizing options")
    @MainActor
    func chromeHostedCellsDeclareSizingOptions() {
        let cell = ThemeTableChrome.HostingCell.make(
            NSUserInterfaceItemIdentifier("cell"),
            in: NSTableView(),
            showing: Text(verbatim: "value")
        )
        #expect(cell.sizingOptions.isEmpty)
    }
}
