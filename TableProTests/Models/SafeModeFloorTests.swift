//
//  SafeModeFloorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct SafeModeFloorTests {
    private func remoteFileConnection(preferred: SafeModeLevel = .silent) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Remote", type: .sqlite, safeModeLevel: preferred)
        connection.sshTunnelMode = .inline(
            SSHConfiguration(enabled: true, host: "ssh.example.com", remoteFilePath: "/srv/app.db")
        )
        return connection
    }

    @Test("A read-only engine outranks a remote file, and both outrank the profile")
    func resolveOrder() {
        let engine = SafeModeFloor.resolve(isEngineReadOnly: true, opensRemoteDatabaseFile: true, managedMinimum: .alert)
        let remote = SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: true, managedMinimum: .alert)
        let managed = SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: false, managedMinimum: .alert)

        #expect(engine == SafeModeFloor(level: .readOnly, reason: .readOnlyEngine))
        #expect(remote == SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile))
        #expect(managed == SafeModeFloor(level: .alert, reason: .managedPolicy))
    }

    @Test("No condition and no profile, or a profile at Silent, leaves no floor", arguments: [nil, SafeModeLevel.silent])
    func noFloor(managedMinimum: SafeModeLevel?) {
        #expect(
            SafeModeFloor.resolve(isEngineReadOnly: false, opensRemoteDatabaseFile: false, managedMinimum: managedMinimum)
                == nil
        )
    }

    @Test("A floor allows its own level and every stricter one", arguments: SafeModeLevel.allCases)
    func allowsStricterLevels(candidate: SafeModeLevel) {
        let floor = SafeModeFloor(level: .safeMode, reason: .managedPolicy)
        let stricter: Set<SafeModeLevel> = [.safeMode, .safeModeFull, .readOnly]

        #expect(floor.allows(candidate) == stricter.contains(candidate))
        #expect(floor.raising(candidate) == (stricter.contains(candidate) ? candidate : .safeMode))
    }

    @Test("The choosable levels are the ones at or above the floor")
    func choosableLevels() {
        #expect(SafeModeFloor.levels(allowedBy: nil) == SafeModeLevel.allCases)
        #expect(SafeModeFloor.levels(allowedBy: SafeModeFloor(level: .readOnly, reason: .readOnlyEngine)) == [.readOnly])
        #expect(
            SafeModeFloor.levels(allowedBy: SafeModeFloor(level: .alertFull, reason: .managedPolicy))
                == [.alertFull, .safeMode, .safeModeFull, .readOnly]
        )
    }

    @Test("The profile's explanation names the level it requires")
    func managedExplanationNamesLevel() {
        let floor = SafeModeFloor(level: .safeModeFull, reason: .managedPolicy)
        #expect(floor.explanation.contains(SafeModeLevel.safeModeFull.displayName))
    }

    /// The agent conversation's context strip has one line for all of this, so it carries the short
    /// form beside the level's symbol and keeps the sentence for its tooltip. Each reason answers for
    /// itself, or the strip would say the same thing whatever is holding the connection.
    @Test("Every reason has a short form of its own, and it is shorter than the sentence")
    func everyReasonSummarisesItself() {
        let reasons: [SafeModeFloor.Reason] = [.readOnlyEngine, .remoteDatabaseFile, .managedPolicy, .agentMode]
        let summaries = reasons.map { SafeModeFloor(level: .alert, reason: $0).summary }

        #expect(Set(summaries).count == reasons.count)
        for (reason, summary) in zip(reasons, summaries) {
            let floor = SafeModeFloor(level: .alert, reason: reason)
            #expect(!summary.isEmpty, "\(reason)")
            #expect(summary.count < floor.explanation.count, "\(reason)")
        }
    }

    @Test("A read-only engine reads as Read-Only and keeps the user's own level", arguments: [
        DatabaseType.cloudflareR2SQL, DatabaseType.beancount
    ])
    func readOnlyEngine(type: DatabaseType) {
        let connection = DatabaseConnection(name: "Engine", type: type, safeModeLevel: .alert)

        #expect(connection.safeModeFloor?.reason == .readOnlyEngine)
        #expect(connection.safeModeLevel == .readOnly)
        #expect(connection.preferredSafeModeLevel == .alert)
    }

    @Test("An engine that takes writes reads as the user's own level")
    func writableEngine() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .alert)

        #expect(connection.safeModeFloor == nil)
        #expect(connection.safeModeLevel == .alert)
    }

    @Test("A connection that opens a remote database file reads as Read-Only")
    func remoteFile() {
        let connection = remoteFileConnection()

        #expect(connection.safeModeFloor?.reason == .remoteDatabaseFile)
        #expect(connection.safeModeLevel == .readOnly)
        #expect(connection.preferredSafeModeLevel == .silent)
    }

    @Test("Assigning the level sets the user's own choice")
    func assignmentSetsPreference() {
        var connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL)
        connection.safeModeLevel = .safeMode

        #expect(connection.preferredSafeModeLevel == .safeMode)
        #expect(connection.safeModeLevel == .readOnly)
    }

    @Test("Encoding writes the user's own level, never the enforced one")
    func codableRoundTrip() throws {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)

        let data = try JSONEncoder().encode(connection)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(object["safeModeLevel"] as? String == SafeModeLevel.silent.rawValue)
        #expect(decoded.preferredSafeModeLevel == .silent)
        #expect(decoded.safeModeLevel == .readOnly)
    }

    @Test("The stored record carries the user's own level")
    func persistenceCarriesPreference() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .alert)

        #expect(StoredConnection(from: connection).safeModeLevel == SafeModeLevel.alert.rawValue)
    }

    @Test("A session starts at the enforced level")
    func sessionSeedsEnforcedLevel() {
        #expect(ConnectionSession(connection: remoteFileConnection()).safeModeLevel == .readOnly)
        let engine = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)
        #expect(ConnectionSession(connection: engine).safeModeLevel == .readOnly)
    }

    @Test("Choosing a weaker level on an enforced session keeps it Read-Only")
    func setSafeModeLevelKeepsEnforcement() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .readOnly)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.setSafeModeLevel(.silent, for: connection.id)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.safeModeLevel == .readOnly)
        #expect(session?.connection.safeModeLevel == .readOnly)
        #expect(session?.connection.preferredSafeModeLevel == .silent)
    }

    @Test("Picking the level already in force on a held connection leaves the saved level alone")
    func chooseOnHeldConnectionKeepsPreference() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.readOnly, for: connection.id)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.connection.preferredSafeModeLevel == .silent)
        #expect(session?.safeModeLevel == .readOnly)
    }

    @Test("Picking a level below the floor changes nothing")
    func chooseBelowFloorIsIgnored() {
        let connection = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .alert)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.silent, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.preferredSafeModeLevel == .alert)
    }

    @Test("Picking a level on an ordinary connection applies it")
    func chooseOnOrdinaryConnectionApplies() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.chooseSafeModeLevel(.safeMode, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.safeModeLevel == .safeMode)
    }

    @Test("Choosing a level on an ordinary session applies it")
    func setSafeModeLevelOnWritableEngine() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .silent)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.setSafeModeLevel(.alert, for: connection.id)

        #expect(DatabaseManager.shared.session(for: connection.id)?.safeModeLevel == .alert)
    }

    /// Agent mode is a fourth, independently-true condition, so the chain had to stop answering the
    /// first match and start answering the strictest. A managed policy at Read-Only outranks it; a
    /// managed policy at Alert ties with it and either reason is correct at that level.
    @Test("Agent mode raises an unrestricted connection to Alert")
    func agentModeRaisesToAlert() throws {
        let floor = try #require(SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: false,
            managedMinimum: nil,
            isAgentModeActive: true
        ))
        #expect(floor.level == .alert)
        #expect(floor.reason == .agentMode)
    }

    @Test("A read-only engine still outranks agent mode")
    func readOnlyEngineOutranksAgentMode() throws {
        let floor = try #require(SafeModeFloor.resolve(
            isEngineReadOnly: true,
            opensRemoteDatabaseFile: false,
            managedMinimum: nil,
            isAgentModeActive: true
        ))
        #expect(floor.level == .readOnly)
        #expect(floor.reason == .readOnlyEngine)
    }

    @Test("A stricter managed policy outranks agent mode")
    func managedPolicyOutranksAgentMode() throws {
        let floor = try #require(SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: false,
            managedMinimum: .readOnly,
            isAgentModeActive: true
        ))
        #expect(floor.level == .readOnly)
        #expect(floor.reason == .managedPolicy)
    }

    @Test("Agent mode never lowers a level the user set higher")
    func agentModeNeverLowers() throws {
        let floor = try #require(SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: false,
            managedMinimum: nil,
            isAgentModeActive: true
        ))
        #expect(floor.raising(.readOnly) == .readOnly)
        #expect(floor.raising(.safeModeFull) == .safeModeFull)
        #expect(floor.raising(.silent) == .alert)
    }

    @Test("Leaving agent mode leaves no floor behind")
    func leavingAgentModeClearsTheFloor() {
        #expect(SafeModeFloor.resolve(
            isEngineReadOnly: false,
            opensRemoteDatabaseFile: false,
            managedMinimum: nil,
            isAgentModeActive: false
        ) == nil)
    }

    // MARK: - What the Safe Mode list offers and takes

    private static let agentFloor = SafeModeFloor(level: .alert, reason: .agentMode)

    /// The defect this closes: a connection set to Silent is held at Alert in Agent mode, and picking
    /// Silent from the list was stored as the user's level while the session stayed at Alert. The
    /// pick changed nothing on screen and came back as their level once the mode ended.
    @Test("Under Agent mode's floor, Silent is neither offered nor taken")
    func agentFloorRefusesALevelBelowIt() {
        let status = SafeModeStatus(level: .alert, floor: Self.agentFloor)

        #expect(!status.offeredLevels.contains(.silent))
        #expect(!status.offers(.silent))
        #expect(!status.accepts(.silent))
    }

    /// Under a floor the level in force can be the floor's rather than the user's. Writing it would
    /// replace the level they chose, with nothing on screen moving.
    @Test("The level in force is offered, and choosing it again is not taken")
    func levelInForceIsNotTakenAgain() {
        let status = SafeModeStatus(level: .alert, floor: Self.agentFloor)

        #expect(status.offers(.alert))
        #expect(!status.accepts(.alert))
    }

    @Test("A stricter level than the one in force is taken under Agent mode's floor")
    func stricterLevelIsTaken() {
        let status = SafeModeStatus(level: .alert, floor: Self.agentFloor)

        for level in [SafeModeLevel.alertFull, .safeMode, .safeModeFull, .readOnly] {
            #expect(status.accepts(level), "\(level)")
        }
    }

    /// The rule the list and the write share: whatever is accepted is a level the floor lets stand,
    /// so storing it moves the level on screen to exactly what was picked.
    @Test("Every choice that is taken moves the level in force to what was picked")
    func everyTakenChoiceMovesTheLevel() {
        let floors: [SafeModeFloor?] = [
            nil,
            Self.agentFloor,
            SafeModeFloor(level: .safeMode, reason: .managedPolicy),
            SafeModeFloor(level: .readOnly, reason: .readOnlyEngine),
        ]
        for floor in floors {
            for preferred in SafeModeLevel.allCases {
                let inForce = floor?.raising(preferred) ?? preferred
                let status = SafeModeStatus(level: inForce, floor: floor)
                for candidate in SafeModeLevel.allCases where status.accepts(candidate) {
                    let after = floor?.raising(candidate) ?? candidate
                    #expect(after == candidate, "\(String(describing: floor)) \(preferred) -> \(candidate)")
                    #expect(after != inForce, "\(String(describing: floor)) \(preferred) -> \(candidate)")
                }
            }
        }
    }

    @Test("With no floor every level is offered")
    func noFloorOffersEveryLevel() {
        let status = SafeModeStatus(level: .silent, floor: nil)

        #expect(status.offeredLevels == SafeModeLevel.allCases)
        #expect(status.accepts(.readOnly))
        #expect(!status.accepts(.silent))
    }

    @Test("The offered levels are the ones the floor allows", arguments: [
        SafeModeFloor(level: .alert, reason: .agentMode),
        SafeModeFloor(level: .alertFull, reason: .managedPolicy),
        SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile),
    ])
    func offeredLevelsFollowTheFloor(floor: SafeModeFloor) {
        let status = SafeModeStatus(level: floor.level, floor: floor)
        #expect(status.offeredLevels == SafeModeFloor.levels(allowedBy: floor))
    }

    @Test("The toolbar tooltip names the level, and the floor's reason when one holds it")
    func toolTipCarriesTheReason() {
        let free = SafeModeStatus(level: .alertFull, floor: nil)
        let held = SafeModeStatus(level: .alert, floor: Self.agentFloor)

        #expect(free.toolTip == String(format: String(localized: "Safe Mode: %@"), SafeModeLevel.alertFull.displayName))
        #expect(held.toolTip.hasPrefix(String(format: String(localized: "Safe Mode: %@"), SafeModeLevel.alert.displayName)))
        #expect(held.toolTip.hasSuffix(Self.agentFloor.explanation))
    }

    /// Nothing is in Agent mode unless a window shows it so, which no window in a unit test does, so
    /// the status is the connection's own: its floor, and its own level raised to it.
    @Test("A connection no window shows in Agent mode is judged against its own floor")
    func statusWithoutAgentModeIsTheConnectionsOwn() {
        let engine = DatabaseConnection(name: "R2", type: .cloudflareR2SQL, safeModeLevel: .alert)
        let plain = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .alert)

        #expect(AgentModeSafeModeFloor.status(for: engine) == SafeModeStatus(
            level: .readOnly,
            floor: SafeModeFloor(level: .readOnly, reason: .readOnlyEngine)
        ))
        #expect(AgentModeSafeModeFloor.status(for: plain) == SafeModeStatus(level: .alert, floor: nil))
    }

    @Test("Picking the level already in force on an ordinary connection writes nothing")
    func chooseCurrentLevelOnOrdinaryConnectionWritesNothing() {
        let connection = DatabaseConnection(name: "PG", type: .postgresql, safeModeLevel: .alert)
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let versionBefore = DatabaseManager.shared.connectionStatusVersions[connection.id]

        DatabaseManager.shared.chooseSafeModeLevel(.alert, for: connection.id)

        #expect(DatabaseManager.shared.connectionStatusVersions[connection.id] == versionBefore)
        #expect(DatabaseManager.shared.session(for: connection.id)?.connection.preferredSafeModeLevel == .alert)
    }
}
