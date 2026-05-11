import Foundation

struct RoutineInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue)_\(qualifiedName)" }
    let name: String
    let schema: String?
    let kind: Kind
    let signature: String?

    enum Kind: String, Sendable {
        case procedure = "PROCEDURE"
        case function = "FUNCTION"

        var sidebarObjectKind: SidebarObjectKind {
            switch self {
            case .procedure: return .procedure
            case .function:  return .function
            }
        }
    }

    var qualifiedName: String {
        if let schema, !schema.isEmpty {
            return "\(schema).\(name)"
        }
        return name
    }

    static func == (lhs: RoutineInfo, rhs: RoutineInfo) -> Bool {
        lhs.kind == rhs.kind && lhs.schema == rhs.schema && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(schema)
        hasher.combine(name)
    }
}
