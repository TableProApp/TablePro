//
//  TableLoadTrigger.swift
//  TablePro
//

import Foundation

internal enum TableLoadTrigger {
    case userInitiated
    case restore
}

// Keyed by tab: a window-wide trigger was consumed against whatever tab was selected when the connection came back.
internal struct ParkedTableLoad: Equatable {
    let tabId: UUID
    let trigger: TableLoadTrigger
}
