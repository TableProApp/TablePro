//
//  WelcomeViewModel+WelcomeSheet.swift
//  TablePro
//

import Foundation

extension WelcomeViewModel {
    func presentWelcomeSheetIfFirstLaunch() {
        guard WelcomeSheetGate.shouldPresent(
            hasSeen: services.appSettingsStorage.hasSeenWelcomeSheet(),
            isUITestSandbox: AppStorageEnvironment.shared.isIsolated,
            uiTestRequestsSheet: UITestLaunchEnvironment.requestsWelcomeSheet
        ) else { return }
        guard !hasPendingPresentation else { return }
        presentsWelcomeSheet = true
    }

    func showWelcomeSheet() {
        guard !hasPendingPresentation else { return }
        presentsWelcomeSheet = true
    }

    func welcomeSheetDidDismiss() {
        services.appSettingsStorage.markWelcomeSheetSeen()
    }

    private var hasPendingPresentation: Bool {
        activeSheet != nil
            || databaseTypeChooser != nil
            || urlImportPresented
            || pluginInstallConnection != nil
            || pluginDiagnostic != nil
            || showConnectionError
    }
}
