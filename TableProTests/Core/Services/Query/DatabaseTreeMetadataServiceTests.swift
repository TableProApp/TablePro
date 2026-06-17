import Foundation
@testable import TablePro
import Testing

@Suite("DatabaseTreeMetadataService")
struct DatabaseTreeMetadataServiceTests {
    private typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey

    @Test("connectionObjectKeys unions table and routine keys for the connection")
    func unionsTableAndRoutineKeys() {
        let connectionId = UUID()
        let tableOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")
        let routineOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "billing")
        let shared = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [tableOnly, shared],
            routineKeys: [routineOnly, shared],
            connectionId: connectionId
        )

        #expect(Set(keys) == [tableOnly, routineOnly, shared])
    }

    @Test("connectionObjectKeys includes a routine key with no matching table key")
    func includesOrphanRoutineKey() {
        let connectionId = UUID()
        let routineOnly = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [ObjectsKey](),
            routineKeys: [routineOnly],
            connectionId: connectionId
        )

        #expect(keys == [routineOnly])
    }

    @Test("connectionObjectKeys excludes keys from other connections")
    func excludesOtherConnections() {
        let connectionId = UUID()
        let other = UUID()
        let mine = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)
        let theirs = ObjectsKey(connectionId: other, database: "shop", schema: nil)

        let keys = DatabaseTreeMetadataService.connectionObjectKeys(
            tableKeys: [mine, theirs],
            routineKeys: [theirs],
            connectionId: connectionId
        )

        #expect(keys == [mine])
    }
}
