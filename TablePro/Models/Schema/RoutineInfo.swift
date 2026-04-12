import Foundation

struct RoutineInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: RoutineType

    enum RoutineType: String, Codable, Sendable {
        case procedure = "PROCEDURE"
        case function = "FUNCTION"
    }
}
