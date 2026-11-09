//
//  FilterControlMetrics.swift
//  TablePro
//

import AppKit
import SwiftUI

// Every row of a rule editor reserves the same width for its pop-ups, measured from AppKit's own
// pop-up button: SwiftUI draws a small one within a point of it on macOS 26 and later, and is one before.
@MainActor
enum FilterControlMetrics {
    private struct PopUpKey: Hashable {
        let titles: [String]
        let pullsDown: Bool
    }

    private static var popUpWidths: [PopUpKey: CGFloat] = [:]
    private static var operatorWidths: [Bool: CGFloat] = [:]

    static func popUpWidth(titles: [String], pullsDown: Bool = false) -> CGFloat {
        let key = PopUpKey(titles: titles, pullsDown: pullsDown)
        if let width = popUpWidths[key] { return width }
        let button = NSPopUpButton(frame: .zero, pullsDown: pullsDown)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.addItems(withTitles: titles)
        let width = ceil(button.intrinsicContentSize.width) + 1
        popUpWidths[key] = width
        return width
    }

    static func operatorWidth(reservesCaseIndicator: Bool) -> CGFloat {
        if let width = operatorWidths[reservesCaseIndicator] { return width }
        let widest = FilterOperator.allCases
            .map { popUpWidth(titles: [$0.displayName], pullsDown: true) }
            .max() ?? 0
        let width = widest + (reservesCaseIndicator ? caseIndicatorWidth : 0)
        operatorWidths[reservesCaseIndicator] = width
        return width
    }

    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static let caseIndicatorSpacing: CGFloat = 3

    // SwiftUI draws a small pop-up no narrower than 29.5pt on macOS 27.
    static let popUpMinimumWidth: CGFloat = 32

    static func operatorMinimumWidth(reservesCaseIndicator: Bool) -> CGFloat {
        popUpMinimumWidth + (reservesCaseIndicator ? caseIndicatorWidth : 0)
    }

    private static var caseIndicatorWidth: CGFloat {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.systemFontSize(for: .small),
            weight: .regular,
            scale: .small
        )
        let image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return caseIndicatorSpacing + ceil(image?.size.width ?? 12)
    }
}

extension View {
    // Lets a pop-up fill the width its row reserves; before macOS 26 a menu pop-up already fills it.
    @ViewBuilder
    func fillsReservedWidth() -> some View {
        if #available(macOS 26.0, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }
}

extension VerticalAlignment {
    private enum FilterRowLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    // The centre of a row's first line, so a wrapped condition keeps the row's controls beside its first line.
    static let filterRowLine = VerticalAlignment(FilterRowLine.self)
}
