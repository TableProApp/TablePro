//
//  CustomizationPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class CustomizationPaneViewModel: ObservableObject {
    @Published var color: ConnectionColor = .none
    @Published var tagIds: [UUID] = []
    @Published var groupId: UUID?
    @Published var safeModeLevel: SafeModeLevel = .silent

    @Published var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] { [] }

    func load(from connection: DatabaseConnection) {
        color = connection.color
        tagIds = connection.tagIds
        groupId = connection.groupId
        safeModeLevel = connection.preferredSafeModeLevel
    }
}
