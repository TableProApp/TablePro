//
//  AppEvents.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class AppEvents {
    static let shared = AppEvents()

    let themeChanged = PassthroughSubject<Void, Never>()

    let connectionStatusChanged = PassthroughSubject<ConnectionStatusChange, Never>()

    private init() {}
}

struct ConnectionStatusChange: Sendable {
    let connectionId: UUID
    let status: ConnectionStatus
}
