import Foundation
@testable import TableProMobile
@testable import TableProModels
import Testing

@Suite("Connection redial detection")
struct ConnectionRedialTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "app"
        )
    }

    @Test("Reordering, renaming, grouping and tagging do not count as a redial")
    func presentationChangesKeepTheSession() {
        let original = connection()

        var renamed = original
        renamed.name = "Production"
        #expect(renamed.dialsTheSameWay(as: original))

        var reordered = original
        reordered.sortOrder = 7
        #expect(reordered.dialsTheSameWay(as: original))

        var grouped = original
        grouped.groupId = UUID()
        #expect(grouped.dialsTheSameWay(as: original))

        var tagged = original
        tagged.tagIds = [UUID()]
        #expect(tagged.dialsTheSameWay(as: original))

        var coloured = original
        coloured.colorTag = "red"
        #expect(coloured.dialsTheSameWay(as: original))
    }

    @Test("Anything that changes where or how the app dials counts as a redial")
    func dialingChangesDropTheSession() {
        let original = connection()

        var rehosted = original
        rehosted.host = "replica.example.com"
        #expect(!rehosted.dialsTheSameWay(as: original))

        var reported = original
        reported.port = 5_433
        #expect(!reported.dialsTheSameWay(as: original))

        var reuser = original
        reuser.username = "readonly"
        #expect(!reuser.dialsTheSameWay(as: original))

        var redatabase = original
        redatabase.database = "analytics"
        #expect(!redatabase.dialsTheSameWay(as: original))

        var retyped = original
        retyped.type = .mysql
        #expect(!retyped.dialsTheSameWay(as: original))

        var tunnelled = original
        tunnelled.sshEnabled = true
        #expect(!tunnelled.dialsTheSameWay(as: original))

        var secured = original
        secured.sslEnabled = true
        #expect(!secured.dialsTheSameWay(as: original))

        var refielded = original
        refielded.additionalFields = ["schema": "reporting"]
        #expect(!refielded.dialsTheSameWay(as: original))
    }
}
