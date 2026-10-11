//
//  EtcdTLSModeField.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum EtcdTLSModeField {
    static let fieldId = "etcdTlsMode"

    static func fieldValue(for mode: SSLMode) -> String {
        switch mode {
        case .disabled:
            return "Disabled"
        case .preferred, .required:
            return "Required"
        case .verifyCa:
            return "VerifyCA"
        case .verifyIdentity:
            return "VerifyIdentity"
        }
    }

    static func sslMode(forFieldValue value: String?) -> SSLMode? {
        switch value {
        case "Required":
            return .required
        case "VerifyCA":
            return .verifyCa
        case "VerifyIdentity":
            return .verifyIdentity
        default:
            return nil
        }
    }
}
