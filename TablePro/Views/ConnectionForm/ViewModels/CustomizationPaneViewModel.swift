//
//  CustomizationPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class CustomizationPaneViewModel {
    var color: ConnectionColor = .none
    var tagIds: [UUID] = []
    var groupId: UUID?
    var safeModeLevel: SafeModeLevel = .silent

    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] { [] }

    func load(from connection: DatabaseConnection) {
        color = connection.color
        tagIds = connection.tagIds
        groupId = connection.groupId
        safeModeLevel = connection.safeModeLevel
    }
}
