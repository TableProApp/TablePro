import CoreSpotlight
import Foundation
@testable import TableProMobile
import Testing

@Suite("Scene intent parsing")
struct SceneIntentTests {
    private let connectionId = UUID()

    @Test("A connect link opens the connection")
    func connectLink() throws {
        let url = try #require(URL(string: "tablepro://connect/\(connectionId.uuidString)"))
        #expect(SceneIntent.parse(url: url) == .openConnection(connectionId, table: nil))
    }

    @Test("A connect link with a table opens that table, as it does on the Mac")
    func tableLink() throws {
        let url = try #require(URL(string: "tablepro://connect/\(connectionId.uuidString)/table/users"))
        #expect(SceneIntent.parse(url: url) == .openConnection(connectionId, table: "users"))
    }

    @Test("A link naming a database still opens the connection")
    func databaseLinkOpensConnection() throws {
        let url = try #require(URL(string: "tablepro://connect/\(connectionId.uuidString)/database/app/table/users"))
        #expect(SceneIntent.parse(url: url) == .openConnection(connectionId, table: nil))
    }

    @Test("A malformed link or another host is ignored")
    func malformedLinks() throws {
        #expect(SceneIntent.parse(url: try #require(URL(string: "tablepro://connect/not-a-uuid"))) == nil)
        #expect(SceneIntent.parse(url: try #require(URL(string: "tablepro://integrations/pair"))) == nil)
        #expect(SceneIntent.parse(url: try #require(URL(string: "https://tablepro.app"))) == nil)
    }

    @Test("A .tablepro file imports, any other file is ignored")
    func files() {
        let share = URL(fileURLWithPath: "/tmp/Team.TablePro")
        #expect(SceneIntent.parse(url: share) == .importConnections(share))
        #expect(SceneIntent.parse(url: URL(fileURLWithPath: "/tmp/notes.txt")) == nil)
    }

    @Test("Spotlight, Handoff and table activities resolve to the connection")
    func activities() {
        let id = connectionId.uuidString
        #expect(
            SceneIntent.parse(activityType: CSSearchableItemActionType, userInfo: [CSSearchableItemActivityIdentifier: id])
                == .openConnection(connectionId, table: nil)
        )
        #expect(
            SceneIntent.parse(activityType: SceneIntent.viewConnectionActivity, userInfo: ["connectionId": id])
                == .openConnection(connectionId, table: nil)
        )
        #expect(
            SceneIntent.parse(
                activityType: SceneIntent.viewTableActivity,
                userInfo: ["connectionId": id, "tableName": "orders"]
            ) == .openConnection(connectionId, table: "orders")
        )
        #expect(SceneIntent.parse(activityType: "com.example.other", userInfo: ["connectionId": id]) == nil)
    }
}
