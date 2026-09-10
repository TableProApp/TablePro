//
//  CompareSyncEligibility.swift
//  TablePro
//
//  Whether a driver reports enough for the comparison the user asked for.
//

import Foundation
import TableProPluginKit

internal enum CompareSyncEligibility {
    static func refusalReason(
        for driver: any PluginDatabaseDriver,
        mode: CompareSyncMode,
        endpointName: String
    ) -> String? {
        let required: PluginCapabilities = mode == .structure ? .schemaCompare : .dataCompare
        guard !driver.capabilities.contains(required) else { return nil }
        switch mode {
        case .structure:
            return String(
                format: String(localized: "%@ does not report structure metadata that can be compared."),
                endpointName
            )
        case .data:
            return String(
                format: String(localized: "%@ does not support reading rows in key order, which data compare needs."),
                endpointName
            )
        }
    }
}
