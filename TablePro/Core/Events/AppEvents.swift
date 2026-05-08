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

    let editorSettingsChanged = PassthroughSubject<Void, Never>()

    let dataGridSettingsChanged = PassthroughSubject<Void, Never>()

    let aiSettingsChanged = PassthroughSubject<Void, Never>()

    let terminalSettingsChanged = PassthroughSubject<Void, Never>()

    let accessibilityTextSizeChanged = PassthroughSubject<Void, Never>()

    private init() {}
}

struct ConnectionStatusChange: Sendable {
    let connectionId: UUID
    let status: ConnectionStatus
}
