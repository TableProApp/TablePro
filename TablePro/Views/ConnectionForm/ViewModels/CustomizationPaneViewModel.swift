//
//  CustomizationPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class CustomizationPaneViewModel {
    var color: ConnectionColor = .none
    var tagId: UUID?
    var groupId: UUID?
    var safeModeLevel: SafeModeLevel = .silent

    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] { [] }

    func load(from connection: DatabaseConnection) {
        color = connection.color
        tagId = connection.tagId
        groupId = connection.groupId
        safeModeLevel = connection.safeModeLevel
    }
}
