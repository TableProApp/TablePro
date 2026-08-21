//
//  MainContentCommandActions+NavigationHistory.swift
//  TablePro
//

import Foundation

/// Back and Forward over the selected tab's browse history, for the View menu and the toolbar.
extension MainContentCommandActions {
    var canNavigateBack: Bool {
        coordinator?.canNavigateBack ?? false
    }

    var canNavigateForward: Bool {
        coordinator?.canNavigateForward ?? false
    }

    func navigateBack() {
        coordinator?.navigateBack()
    }

    func navigateForward() {
        coordinator?.navigateForward()
    }
}
