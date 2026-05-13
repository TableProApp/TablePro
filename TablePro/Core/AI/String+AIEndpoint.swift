//
//  String+AIEndpoint.swift
//  TablePro
//

import Foundation

extension String {
    func normalizedEndpoint() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
