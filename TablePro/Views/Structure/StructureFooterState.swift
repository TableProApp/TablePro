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

    func deactivate() {
        isActive = false
        canAdd = false
        canRemove = false
        addLabel = ""
        removeLabel = ""
    }
}
