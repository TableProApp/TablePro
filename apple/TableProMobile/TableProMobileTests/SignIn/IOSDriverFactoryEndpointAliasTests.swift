import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

private final class FixedCNAMEResolver: CNAMEResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let records: [String: String]
    private var asked: [String] = []

    init(_ records: [String: String]) {
        self.records = records
    }

    var queried: [String] {
        lock.withLock { asked }
    }

    func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup {
        lock.withLock {
            asked.append(name)
            return records[name].map(CNAMELookup.found) ?? .failed
        }
    }
}

struct IOSDriverFactoryEndpointAliasTests {
    private static let alias = "reader.db.example.com"
    private static let endpoint = "replica-a.abc123.us-east-1.rds.amazonaws.com"

    private func connection(
        type: DatabaseType = .mysql,
        method: IAMSignIn? = .awsProfile,
        sshEnabled: Bool = false
    ) -> DatabaseConnection {
        var fields: [String: String] = [:]
        fields[IAMSignIn.Field.method] = method?.pickerValue
        return DatabaseConnection(
            type: type,
            host: Self.alias,
            port: 3_306,
            username: "iam_user",
            additionalFields: fields,
            sshEnabled: sshEnabled,
            sshConfiguration: sshEnabled ? SSHConfiguration(host: "bastion.example.com", username: "ec2-user") : nil
        )
    }

    @Test("An AWS IAM connection to a CNAME dials the RDS endpoint it stands for")
    func awsConnectionDialsTheEndpoint() async throws {
        let resolver = FixedCNAMEResolver([Self.alias: Self.endpoint])
        let factory = IOSDriverFactory(cnameResolver: resolver)

        for type in [DatabaseType.mysql, .mariadb, .postgresql] {
            let resolved = try await factory.resolvingEndpointAlias(for: connection(type: type))
            #expect(resolved.host == Self.endpoint, "\(type)")
        }
    }

    @Test("Nothing is looked up behind SSH, without AWS IAM, or for ElastiCache")
    func otherConnectionsAreNotLookedUp() async throws {
        let resolver = FixedCNAMEResolver([Self.alias: Self.endpoint])
        let factory = IOSDriverFactory(cnameResolver: resolver)

        for saved in [
            connection(sshEnabled: true),
            connection(method: nil),
            connection(method: .googleApplicationDefault),
            connection(type: .redis)
        ] {
            #expect(try await factory.resolvingEndpointAlias(for: saved).host == Self.alias)
        }
        #expect(resolver.queried.isEmpty)
    }

    @Test("A lookup that fails stops the connect with an error naming the host")
    func failedLookupThrows() async {
        let factory = IOSDriverFactory(cnameResolver: FixedCNAMEResolver([:]))

        await #expect(throws: AWSAuthError.endpointLookupFailed(host: Self.alias)) {
            _ = try await factory.resolvingEndpointAlias(for: connection())
        }
    }
}
