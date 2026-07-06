//
//  TableLoadTrigger.swift
//  TablePro
//

import Foundation

internal enum TableLoadTrigger {
    case userInitiated
    case restore

    var suppressesFailureModal: Bool {
        self == .restore
    }
}
