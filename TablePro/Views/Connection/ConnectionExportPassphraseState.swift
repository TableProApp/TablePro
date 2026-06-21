//
//  ConnectionExportPassphraseState.swift
//  TablePro
//

import Foundation

enum ConnectionExportPassphraseState: Equatable {
    case empty
    case tooShort
    case incomplete
    case mismatch
    case ok

    static let minimumLength = 8

    static func evaluate(passphrase: String, confirmation: String) -> ConnectionExportPassphraseState {
        if passphrase.isEmpty { return .empty }
        if (passphrase as NSString).length < minimumLength { return .tooShort }
        if confirmation.isEmpty { return .incomplete }
        if passphrase != confirmation { return .mismatch }
        return .ok
    }

    var allowsExport: Bool {
        self == .ok
    }
}
