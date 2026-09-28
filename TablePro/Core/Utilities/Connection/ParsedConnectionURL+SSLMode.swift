//
//  ParsedConnectionURL+SSLMode.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension ParsedConnectionURL {
    var resolvedPort: Int {
        port ?? type.portWhenOmitted(tlsEnabled: (explicitSSLMode ?? .disabled) != .disabled)
    }

    var sslModeResolution: SSLModeResolution {
        let resolution = explicitSSLMode.map { SSLModeResolution(mode: $0, origin: .chosen) }
            ?? type.sslModeResolution(forPort: resolvedPort)
        guard useSrv, resolution.mode == .disabled else { return resolution }
        return SSLModeResolution(mode: .required, origin: .chosen)
    }

    private var explicitSSLMode: SSLMode? {
        sslMode ?? (disablesTLS ? .disabled : nil)
    }
}
