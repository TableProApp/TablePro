import Foundation

enum SyncRecordChanges {
    static func changedIds<Record: Identifiable & Equatable>(
        from previous: [Record],
        to current: [Record]
    ) -> [String] where Record.ID == UUID {
        let previousById = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return current
            .filter { previousById[$0.id] != $0 }
            .map { $0.id.uuidString }
    }
}
