import Foundation

struct RoutineParameterInfo: Identifiable, Hashable {
    var id: String { "\(ordinalPosition)_\(name ?? "")" }
    let name: String?
    let dataType: String
    let direction: String
    let ordinalPosition: Int
    let defaultValue: String?
}
