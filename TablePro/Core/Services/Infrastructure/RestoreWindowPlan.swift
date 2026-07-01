//
//  RestoreWindowPlan.swift
//  TablePro
//

import Foundation

enum RestoreWindowPlan {
    static func resolveFrontTabId(remainingTabIds: [UUID], firstTabId: UUID, selectedId: UUID?) -> UUID {
        guard let selectedId else { return firstTabId }
        if selectedId == firstTabId { return firstTabId }
        if remainingTabIds.contains(selectedId) { return selectedId }
        return firstTabId
    }
}
