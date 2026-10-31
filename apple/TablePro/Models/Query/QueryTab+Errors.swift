//
//  QueryTab+Errors.swift
//  TablePro
//

import Foundation

struct QueryTabError: Equatable {
    let message: String
    let query: String?
    // Only the tab's own message can be dismissed: an Error result's message is that result.
    let isDismissible: Bool
}

extension QueryTab {
    // The tab's message is the newer failure, so it shows ahead of the one the active result recorded when it ran.
    @MainActor
    var shownError: QueryTabError? {
        if let message = execution.errorMessage {
            return QueryTabError(message: message, query: execution.errorQuery, isDismissible: true)
        }
        guard let active = display.activeResultSet, let message = active.errorMessage else { return nil }
        return QueryTabError(message: message, query: active.failedQuery, isDismissible: false)
    }

    // What Fix with AI works from while another result is on screen: the failure still belongs to this tab.
    @MainActor
    var latestError: QueryTabError? {
        if let shownError { return shownError }
        guard let failed = display.resultSets.last(where: { $0.errorMessage != nil }),
              let message = failed.errorMessage else { return nil }
        return QueryTabError(message: message, query: failed.failedQuery, isDismissible: false)
    }
}
