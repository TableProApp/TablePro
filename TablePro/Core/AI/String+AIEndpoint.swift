//
//  String+AIEndpoint.swift
//  TablePro
//

import Foundation

extension String {
    func normalizedEndpoint() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }

    func openAIPath(_ resource: String) -> String {
        let base = normalizedEndpoint()
        return base.hasSuffix("/v1") ? "\(base)/\(resource)" : "\(base)/v1/\(resource)"
    }
}
