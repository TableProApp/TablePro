//
//  TableLoadTrigger.swift
//  TablePro
//

import Foundation

internal enum TableLoadTrigger {
    case userInitiated
    case restore
    case autoRefresh

    // A timer's read at 5 s would write 720 rows an hour per tab.
    var recordsHistory: Bool {
        switch self {
        case .userInitiated, .restore: true
        case .autoRefresh: false
        }
    }

    // At 5 s a tick's trace would push every real load out of the diagnostics store within hours.
    var tracesLoad: Bool {
        switch self {
        case .userInitiated, .restore: true
        case .autoRefresh: false
        }
    }

    // A count slower than the interval would otherwise run on every tick and never land; only a manual Refresh recounts.
    var countsRows: Bool {
        switch self {
        case .userInitiated, .restore: true
        case .autoRefresh: false
        }
    }
}

// Keyed by tab: a window-wide trigger was consumed against whatever tab was selected when the connection came back.
internal struct ParkedTableLoad: Equatable {
    let tabId: UUID
    let trigger: TableLoadTrigger
}
