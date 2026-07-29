import Foundation

struct WidgetConnectionItem: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let type: String
    let sortOrder: Int
}
