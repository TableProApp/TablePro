import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

struct TeamLibraryItemsTests {
    @Test("A team connection lands without what the app would run by itself")
    func connectionDropsWhatRuns() throws {
        let item = TeamLibraryFixtures.connection(
            "C1",
            name: "Orders",
            extra: [
                "startupCommands": "SET search_path TO app",
                "tunnelCommand": ["method": "command", "command": "ssh -L 5432:db:5432 bastion"],
            ]
        )

        let team = TeamLibraryTeam(TeamLibraryFixtures.team("team_a", items: [item]))

        let connection = try #require(team.connections.first)
        #expect(connection.id == "c1")
        #expect(connection.settings.startupCommands == nil)
        #expect(connection.settings.tunnelCommand == nil)
        #expect(connection.ref == TeamLibraryItemRef(kind: .connection, id: "c1"))
    }

    @Test("A connection whose SSH host ssh would refuse is left out")
    func refusedSSHHostIsLeftOut() {
        let item = TeamLibraryFixtures.connection(
            "C1",
            name: "Orders",
            extra: [
                "sshConfig": [
                    "enabled": true,
                    "host": "-oProxyCommand=touch /tmp/x",
                    "port": 22,
                    "username": "deploy",
                    "authMethod": "password",
                    "privateKeyPath": "",
                    "agentSocketPath": "",
                ] as [String: Any],
            ]
        )

        #expect(TeamLibraryTeam(TeamLibraryFixtures.team("team_a", items: [item])).connections.isEmpty)
    }

    @Test("Queries sort by folder, then position, then name, and carry their folder's name")
    func queriesSortByFolder() {
        let info = TeamLibraryFixtures.team("team_a", items: [
            TeamLibraryFixtures.folder("F1", name: "Reports"),
            TeamLibraryFixtures.query("Q2", name: "Weekly", sql: "SELECT 2", folder: "f1", order: 1),
            TeamLibraryFixtures.query("Q1", name: "Daily", sql: "SELECT 1", folder: "F1", order: 0),
            TeamLibraryFixtures.query("Q3", name: "Loose", sql: "SELECT 3"),
        ])

        let team = TeamLibraryTeam(info)

        #expect(team.queries.map(\.name) == ["Loose", "Daily", "Weekly"])
        #expect(team.queries.last?.folderName == "Reports")
    }

    @Test("Who changed an item last is trimmed, an empty name is no one, and the time reads in seconds")
    func lastChange() {
        let named = TeamLibraryChange(TeamLibraryFixtures.connection("C1", name: "A", updatedBy: "  Ana  ", updatedAtMs: 1_500))
        let blank = TeamLibraryChange(TeamLibraryFixtures.connection("C2", name: "B", updatedBy: "   "))

        #expect(named.writer == "Ana")
        #expect(named.date == Date(timeIntervalSince1970: 1.5))
        #expect(blank.writer == nil)
        #expect(!blank.isKnown)
    }

    @Test("A team with no name reads as Team Library, and a role decides who manages keys")
    func teamNameAndRole() {
        let unnamed = TeamLibraryTeam(TeamLibraryFixtures.team("team_a", name: nil, role: .admin))
        let editor = TeamLibraryTeam(TeamLibraryFixtures.team("team_b", name: "Data", role: .editor))

        #expect(unnamed.name == String(localized: "Team Library"))
        #expect(unnamed.managesKeys)
        #expect(!editor.managesKeys)
    }

    @Test("A team item's copy keeps one id for that team and item, whatever case the item id is in")
    func copyIdIsStable() {
        let first = TeamLibraryID.copy(team: "team_a", item: "C1")

        #expect(first == TeamLibraryID.copy(team: "team_a", item: "c1"))
        #expect(first != TeamLibraryID.copy(team: "team_b", item: "c1"))
        #expect(first.uuidString.dropFirst(14).first == "8")
    }

    @Test("A directional control or line break in another member's text shows as its code point")
    func hiddenCharactersShow() {
        #expect(TeamLibraryVisibleText.name("abc\u{202E}def") == "abc<U+202E>def")
        #expect(TeamLibraryVisibleText.name("a\nb") == "a<U+000A>b")
        #expect(TeamLibraryVisibleText.visible("a\nb", keepingLineBreaks: true) == "a\nb")
        #expect(TeamLibraryVisibleText.name(String(repeating: "x", count: 100)).count == TeamLibraryVisibleText.nameLimit + 1)
    }

    @Test("Each engine code reads as the problem the Mac names it, and only a passing one waits")
    func problemCodes() {
        #expect(TeamLibraryProblem(code: "sync.team_library.not_pulled") == .offline)
        #expect(TeamLibraryProblem(code: "library_write_forbidden") == .writeForbidden)
        #expect(TeamLibraryProblem(code: "sync.team_library.pull_only") == .licenseExpired)
        #expect(TeamLibraryProblem(code: "sync.team_library.delete_failed") == .deletePending)
        #expect(TeamLibraryProblem(code: "sync.seat_required") == .unreadable)
        #expect(TeamLibraryProblem(code: "something.else") == .refused)
        #expect(TeamLibraryProblem(FakeTeamLibraryCalls.failure("sync.rate_limited")).isRetryable)
        #expect(!TeamLibraryProblem(CancellationError()).isRetryable)
    }
}
