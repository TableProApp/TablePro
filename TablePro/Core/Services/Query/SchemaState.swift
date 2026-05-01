//
//  SchemaState.swift
//  TablePro
//

import Foundation

enum SchemaState: Equatable, Sendable {
    case idle
    case loading
    case loaded([TableInfo])
    case failed(String)
}
