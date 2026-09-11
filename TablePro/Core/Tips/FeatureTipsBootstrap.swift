//
//  FeatureTipsBootstrap.swift
//  TablePro
//

import Foundation
import os
import TipKit

@MainActor
internal enum FeatureTipsBootstrap {
    private static let logger = Logger(subsystem: "com.TablePro", category: "FeatureTips")

    private(set) static var plan: FeatureTipsPlan?

    static func configure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storage: AppStorageEnvironment = .shared
    ) {
        guard plan == nil else { return }
        guard let resolved = FeatureTipsPlan.resolve(
            isUnitTestHost: environment["XCTestConfigurationFilePath"] != nil,
            isIsolated: storage.isIsolated,
            supportDirectory: storage.supportDirectory,
            requestedTipIds: environment[FeatureTipsPlan.showTipsVariable]
        ) else { return }
        plan = resolved

        switch resolved.visibility {
        case .normal:
            break
        case .hideAll:
            Tips.hideAllTipsForTesting()
        case .showOnly(let ids):
            Tips.showTipsForTesting(FeatureTipCatalog.types(for: ids))
        }

        do {
            try Tips.configure([
                .datastoreLocation(.url(resolved.datastoreDirectory)),
                .displayFrequency(resolved.visibility == .normal ? .daily : .immediate)
            ])
        } catch {
            logger.error("Could not configure tips: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func allows(_ tipId: String) -> Bool {
        plan?.allows(tipId) ?? false
    }
}

@MainActor
internal enum FeatureTipSignals {
    static func sidebarTableOpened() {
        donate(OpenQuicklyTip.sidebarTableOpened)
    }

    static func previewTabReplaced() {
        donate(KeepTableOpenTip.previewTabReplaced)
    }

    static func editorQueryRan() {
        donate(FindPastQueriesTip.editorQueryRan)
    }

    static func tableKeptOpen() {
        invalidate(KeepTableOpenTip())
    }

    static func quickSwitcherOpened() {
        invalidate(OpenQuicklyTip())
    }

    static func queryHistoryShown() {
        invalidate(FindPastQueriesTip())
    }

    private static func donate(_ event: Tips.Event<Tips.EmptyDonation>) {
        guard FeatureTipsBootstrap.plan != nil else { return }
        event.sendDonation()
    }

    private static func invalidate(_ tip: some Tip) {
        guard FeatureTipsBootstrap.plan != nil else { return }
        tip.invalidate(reason: .actionPerformed)
    }
}
