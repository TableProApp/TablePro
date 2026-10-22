//
//  ResultComparisonWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class ResultComparisonWindowController: ValueViewerWindowController {
    private var model: ResultComparisonModel?

    @discardableResult
    static func open(model: ResultComparisonModel) -> ResultComparisonWindowController {
        let controller = ResultComparisonWindowController()
        controller.model = model
        controller.present(
            identifier: "result-comparison",
            title: String(localized: "Compare Results"),
            autosaveName: "ResultComparisonWindow",
            size: NSSize(width: 960, height: 600)
        ) { _ in
            ResultComparisonView(model: model)
        }
        return controller
    }
}
