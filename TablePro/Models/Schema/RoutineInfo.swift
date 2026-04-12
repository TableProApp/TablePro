import Foundation

struct RoutineInfo: Identifiable, Hashable {
    var id: String { "\(name)_\(type.rawValue)" }
    let name: String
    let type: RoutineType

    enum RoutineType: String, Sendable {
        case procedure = "PROCEDURE"
        case function = "FUNCTION"
    }
}
