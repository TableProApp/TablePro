//
//  TunnelCommandPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class TunnelCommandPaneViewModel: ObservableObject {
    @Published var state = TunnelCommandFormState()

    @Published var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        return TunnelCommandBuilder.validationIssues(for: state.buildConfig())
    }

    func load(from connection: DatabaseConnection) {
        state.load(from: connection)
    }
}
