//
//  AppleIntelligenceAvailability.swift
//  TablePro
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceAvailability {
    static func currentStatus() -> AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .osNotSupported }
        return statusFromFramework()
        #else
        return .osNotSupported
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func statusFromFramework() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknown
            }
        @unknown default:
            return .unknown
        }
    }
    #endif
}
