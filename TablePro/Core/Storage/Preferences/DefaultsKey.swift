//
//  DefaultsKey.swift
//  TablePro
//

import Foundation

struct DefaultsKey<Value>: @unchecked Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}
