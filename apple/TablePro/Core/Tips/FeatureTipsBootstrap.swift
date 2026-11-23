//
//  FeatureTipsBootstrap.swift
//  TablePro
//

import Foundation
import os
import TipKit

@available(macOS 14.0, *)
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
            logger.error("Could not configure tips: \(error.publicLogShape, privacy: .public)")
        }
    }

    static func allows(_ tipId: String) -> Bool {
        plan?.allows(tipId) ?? false
    }
}

@available(macOS 14.0, *)
@MainActor
internal enum FeatureTipSignals {
    static func sidebarTableOpened() {
        donate(OpenQuicklyTip.sidebarTableOpened, for: OpenQuicklyTip(), enough: nil)
    }

    static func previewTabReplaced() {
        donate(KeepTableOpenTip.previewTabReplaced, for: KeepTableOpenTip(), enough: nil)
    }

    static func editorQueryRan() {
        donate(FindPastQueriesTip.editorQueryRan, for: FindPastQueriesTip(), enough: FindPastQueriesTip.queryRunsCounted)
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

    // Each donation is a write to the tips store, so one that no rule can count is not sent.
    private static func donate(_ event: Tips.Event<Tips.EmptyDonation>, for tip: some Tip, enough: Int?) {
        guard FeatureTipsBootstrap.plan != nil else { return }
        let donations = enough == nil ? 0 : event.donations.count
        guard FeatureTipDonation.isNeeded(status: tip.status, donations: donations, enough: enough) else { return }
        event.sendDonation()
    }

    private static func invalidate(_ tip: some Tip) {
        guard FeatureTipsBootstrap.plan != nil else { return }
        tip.invalidate(reason: .actionPerformed)
    }
}
