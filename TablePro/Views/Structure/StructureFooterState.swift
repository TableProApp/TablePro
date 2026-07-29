//
//  StructureFooterState.swift
//  TablePro
//

import Foundation
import Observation

@Observable
@MainActor
final class StructureFooterState {
    var isActive: Bool = false
    var canAdd: Bool = false
    var canRemove: Bool = false
    var addLabel: String = ""
    var removeLabel: String = ""

    private(set) var currentOwner: UUID?

    func update(
        owner: UUID,
        canAdd: Bool,
        canRemove: Bool,
        addLabel: String,
        removeLabel: String
    ) {
        currentOwner = owner
        isActive = true
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.addLabel = addLabel
        self.removeLabel = removeLabel
    }

    func deactivate(owner: UUID) {
        guard currentOwner == owner else { return }
        currentOwner = nil
        isActive = false
        canAdd = false
        canRemove = false
        addLabel = ""
        removeLabel = ""
    }
}
