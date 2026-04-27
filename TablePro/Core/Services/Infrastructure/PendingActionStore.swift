//
//  PendingActionStore.swift
//  TablePro
//

import Foundation

@MainActor @Observable
final class PendingActionStore {
    static let shared = PendingActionStore()

    var connectionShareURL: URL?
    var deeplinkImport: ExportableConnection?

    private init() {}

    func consumeConnectionShareURL() -> URL? {
        let url = connectionShareURL
        connectionShareURL = nil
        return url
    }

    func consumeDeeplinkImport() -> ExportableConnection? {
        let value = deeplinkImport
        deeplinkImport = nil
        return value
    }
}
