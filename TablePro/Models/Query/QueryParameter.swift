//
//  QueryParameter.swift
//  TablePro
//

import Foundation

enum QueryParameterType: String, Codable, CaseIterable, Sendable {
    case string
    case integer
    case decimal
    case date
    case boolean
}

struct QueryParameter: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    var value: String
    var type: QueryParameterType
    var isNull: Bool

    init(name: String, value: String = "", type: QueryParameterType = .string, isNull: Bool = false) {
        self.id = UUID()
        self.name = name
        self.value = value
        self.type = type
        self.isNull = isNull
    }
}
