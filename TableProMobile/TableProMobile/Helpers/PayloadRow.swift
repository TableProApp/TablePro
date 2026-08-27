import Foundation

nonisolated enum PayloadValue: Equatable {
    case null
    case text(String)

    var isEmptyOrNull: Bool {
        switch self {
        case .null:
            return true
        case .text(let value):
            return value.isEmpty
        }
    }

    var sqlValue: String? {
        switch self {
        case .null:
            return nil
        case .text(let value):
            return value
        }
    }
}

nonisolated struct PayloadRow: Equatable {
    let values: [String: PayloadValue]

    var keys: [String] {
        Array(values.keys)
    }

    func value(for column: String) -> PayloadValue? {
        values[column]
    }
}
