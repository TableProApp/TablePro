//
//  String+Blank.swift
//  TablePro
//
//  Blank-string check that treats whitespace-only strings as empty.
//

import Foundation

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
