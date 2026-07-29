//
//  KeychainStringResult+Value.swift
//  TablePro
//

import Foundation
import os

extension KeychainStringResult {
    /// Maps a Keychain read to its string value, returning nil for every
    /// non-fatal outcome and logging the recoverable failures under `label`.
    func value(label: String, logger: Logger) -> String? {
        switch self {
        case .found(let value):
            return value
        case .notFound:
            return nil
        case .locked:
            logger.warning("\(label, privacy: .public) unavailable: Keychain locked")
            return nil
        case .userCancelled:
            logger.notice("\(label, privacy: .public) prompt cancelled")
            return nil
        case .authFailed:
            logger.warning("\(label, privacy: .public) auth failed")
            return nil
        case .error(let status):
            logger.error("\(label, privacy: .public) read error \(status)")
            return nil
        }
    }
}
