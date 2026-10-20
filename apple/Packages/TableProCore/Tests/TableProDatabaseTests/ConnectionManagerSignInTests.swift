import Foundation
@testable import TableProDatabase
import TableProModels
import TableProTestSupport
import Testing

private struct MintFailure: Error {}

private struct MintRequest: Sendable {
    let host: String
    let port: Int
    let stored: String?
}

private struct DriverRequest: Sendable {
    let host: String
    let port: Int
    let password: String?
    let preTunnelHost: String?
}

private final class SigningDriverFactory: DriverFactory, @unchecked Sendable {
    var mint: @Sendable (String?) async throws -> String? = { stored in stored }
    private(set) var mintRequests: [MintRequest] = []
    private(set) var driverRequests: [DriverRequest] = []

    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String? {
        mintRequests.append(MintRequest(host: connection.host, port: connection.port, stored: stored))
        return try await mint(stored)
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        try createDriver(for: connection, password: password, preTunnelHost: nil)
    }

    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?
    ) throws -> any DatabaseDriver {
        driverRequests.append(DriverRequest(
            host: connection.host,
            port: connection.port,
            password: password,
            preTunnelHost: preTunnelHost
        ))
        return MockDatabaseDriver()
    }

    func supportedTypes() -> [DatabaseType] { [] }
}

private final class PasswordRecordingFactory: DriverFactory, @unchecked Sendable {
    private(set) var passwords: [String?] = []

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        passwords.append(password)
        return MockDatabaseDriver()
    }

    func supportedTypes() -> [DatabaseType] { [] }
}

private func passwordKey(for connection: DatabaseConnection) -> String {
    "com.TablePro.password.\(connection.id.uuidString)"
}

private func rdsConnection(tunneled: Bool) -> DatabaseConnection {
    DatabaseConnection(
        name: "RDS",
        type: DatabaseType(rawValue: "mock"),
        host: "mydb.abc123.us-east-1.rds.amazonaws.com",
        port: 5_432,
        username: "iam_user",
        additionalFields: ["awsAuth": "accessKey"],
        sshEnabled: tunneled,
        sshConfiguration: tunneled ? SSHConfiguration(host: "bastion.example.com") : nil
    )
}

@Suite(.timeLimit(.minutes(1)))
struct ConnectionManagerSignInTests {
    @Test("The minted password reaches the driver in place of the stored one")
    func mintedPasswordReachesTheDriver() async throws {
        let connection = rdsConnection(tunneled: false)
        let factory = SigningDriverFactory()
        factory.mint = { _ in "signed-token" }
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(passwords: [passwordKey(for: connection): "stored-secret"])
        )

        _ = try await manager.connect(connection)

        let mint = try #require(factory.mintRequests.first)
        #expect(mint.stored == "stored-secret")
        let driver = try #require(factory.driverRequests.first)
        #expect(driver.password == "signed-token")
    }

    @Test("A factory without sign-in still hands the stored password to its driver")
    func defaultResolutionPassesTheStoredPassword() async throws {
        let connection = rdsConnection(tunneled: false)
        let factory = PasswordRecordingFactory()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(passwords: [passwordKey(for: connection): "stored-secret"])
        )

        _ = try await manager.connect(connection)

        #expect(factory.passwords == ["stored-secret"])
    }

    @Test("A mint failure throws before any tunnel opens, so no SSH prompt follows it")
    func mintFailureThrowsBeforeTheTunnel() async throws {
        let factory = SigningDriverFactory()
        factory.mint = { _ in throw MintFailure() }
        let ssh = MockSSHProvider()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore(), sshProvider: ssh)
        let connection = rdsConnection(tunneled: true)

        await #expect(throws: MintFailure.self) {
            _ = try await manager.connect(connection)
        }

        #expect(ssh.openedTunnelIds.isEmpty)
        #expect(factory.driverRequests.isEmpty)
        #expect(manager.session(for: connection.id) == nil)
    }

    @Test("An attempt invalidated during the mint throws CancellationError and opens no tunnel")
    func attemptInvalidatedDuringTheMintStops() async throws {
        let gate = AsyncGate()
        let factory = SigningDriverFactory()
        factory.mint = { _ in
            await gate.wait()
            return "signed-token"
        }
        let ssh = MockSSHProvider()
        let manager = ConnectionManager(driverFactory: factory, secureStore: MockSecureStore(), sshProvider: ssh)
        let connection = rdsConnection(tunneled: true)

        let attempt = Task { try await manager.connect(connection) }
        await gate.arrived(1)
        manager.invalidateAttempt(for: connection.id)
        await gate.open()

        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(ssh.openedTunnelIds.isEmpty)
        #expect(factory.driverRequests.isEmpty)
        #expect(manager.session(for: connection.id) == nil)
    }

    @Test("Through a tunnel, the mint sees the saved endpoint and the driver gets the saved host as preTunnelHost")
    func tunneledConnectPassesTheSavedHost() async throws {
        let factory = SigningDriverFactory()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: MockSSHProvider()
        )
        let connection = rdsConnection(tunneled: true)

        _ = try await manager.connect(connection)

        let mint = try #require(factory.mintRequests.first)
        #expect(mint.host == connection.host)
        #expect(mint.port == connection.port)
        let driver = try #require(factory.driverRequests.first)
        #expect(driver.host == "127.0.0.1")
        #expect(driver.port == 33_306)
        #expect(driver.preTunnelHost == connection.host)
    }

    @Test("Without a tunnel, the driver dials the saved host and gets no preTunnelHost")
    func directConnectHasNoPreTunnelHost() async throws {
        let factory = SigningDriverFactory()
        let manager = ConnectionManager(
            driverFactory: factory,
            secureStore: MockSecureStore(),
            sshProvider: MockSSHProvider()
        )
        let connection = rdsConnection(tunneled: false)

        _ = try await manager.connect(connection)

        let driver = try #require(factory.driverRequests.first)
        #expect(driver.host == connection.host)
        #expect(driver.preTunnelHost == nil)
    }
}
