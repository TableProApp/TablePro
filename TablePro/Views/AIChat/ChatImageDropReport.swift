//
//  ChatImageDropReport.swift
//  TablePro
//

import Foundation

/// What to tell the user after a drop that carried more than one file. Reporting only when every
/// file failed is what let a mixed drop attach one image and discard the rest in silence, so the
/// prompt went out referring to images the model never received.
internal enum ChatImageDropReport {
    static func message(attached: Int, failures: [String]) -> String? {
        guard let first = failures.first else { return nil }

        if attached == 0 {
            guard failures.count > 1 else { return first }
            return String(
                format: String(localized: "Could not attach %1$d files. %2$@"),
                failures.count,
                first
            )
        }

        return String(
            format: String(localized: "Attached %1$d of %2$d files. %3$@"),
            attached,
            attached + failures.count,
            first
        )
    }
}
