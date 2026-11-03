import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import Testing

@MainActor
struct TransientConnectionFactoryTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    private func replacingFields(of parsed: ParsedConnectionURL, with fields: [String: String]) -> ParsedConnectionURL {
        ParsedConnectionURL(
            type: parsed.type,
            host: parsed.host,
            port: parsed.port,
            database: parsed.database,
            username: parsed.username,
            password: parsed.password,
            sslMode: parsed.sslMode,
            disablesTLS: parsed.disablesTLS,
            authSource: parsed.authSource,
            sshHost: parsed.sshHost,
            sshPort: parsed.sshPort,
            sshUsername: parsed.sshUsername,
            sshPassword: parsed.sshPassword,
            usePrivateKey: parsed.usePrivateKey,
            useSSHAgent: parsed.useSSHAgent,
            sshNoAuth: parsed.sshNoAuth,
            agentSocket: parsed.agentSocket,
            connectionName: parsed.connectionName,
            redisDatabase: parsed.redisDatabase,
            statusColor: parsed.statusColor,
            envTag: parsed.envTag,
            schema: parsed.schema,
            tableName: parsed.tableName,
            isView: parsed.isView,
            filterColumn: parsed.filterColumn,
            filterOperation: parsed.filterOperation,
            filterValue: parsed.filterValue,
            filterCondition: parsed.filterCondition,
            oracleServiceName: parsed.oracleServiceName,
            safeModeLevel: parsed.safeModeLevel,
            useSrv: parsed.useSrv,
            mongoQueryParams: parsed.mongoQueryParams,
            multiHost: parsed.multiHost,
            additionalFields: fields
        )
    }

    @Test("A MONGODB-AWS link keeps its mechanism, so the consent prompt names the AWS sign-in")
    func mongoAWSLinkKeepsTheSelector() throws {
        let connection = TransientConnectionFactory.build(from: try parse("mongodb://h/?authMechanism=MONGODB-AWS"))

        #expect(connection.origin == .link)
        #expect(connection.additionalFields["mongoAuthMechanism"] == "MONGODB-AWS")
        #expect(
            ConnectionFieldCatalog.localCredentialUses(in: connection.additionalFields)
                == [LocalCredentialUse(fieldId: "mongoAuthMechanism", value: "MONGODB-AWS")]
        )
    }

    @Test("A link's other Mongo options stay on the connection")
    func mongoOptionsSurvive() throws {
        let connection = TransientConnectionFactory.build(
            from: try parse("mongodb://h/app?retryWrites=true&uuidRepresentation=javaLegacy")
        )

        #expect(connection.additionalFields["mongoParam_retryWrites"] == "true")
        #expect(connection.additionalFields["mongoUuidRepresentation"] == "javaLegacy")
    }

    @Test("A link's fields keep what the catalog knows and drop host-internal and unknown keys")
    func linkFieldsAreFiltered() throws {
        let parsed = replacingFields(of: try parse("postgresql://db.example.com:5432/app"), with: [
            RemoteSQLiteWire.backendFieldKey: RemoteSQLiteWire.agentBackendValue,
            RemoteSQLiteWire.tokenFieldKey: "planted",
            "driverVariant": "TiDB",
            "zzzFutureSelector": "1",
            "trinoSchema": "analytics",
        ])

        let connection = TransientConnectionFactory.build(from: parsed)

        #expect(connection.additionalFields[RemoteSQLiteWire.backendFieldKey] == nil)
        #expect(connection.additionalFields[RemoteSQLiteWire.tokenFieldKey] == nil)
        #expect(connection.additionalFields["driverVariant"] == nil)
        #expect(connection.additionalFields["zzzFutureSelector"] == nil)
        #expect(connection.additionalFields["trinoSchema"] == "analytics")
    }

    @Test("A Trino link's schema still reaches the connection")
    func parserFieldsSurvive() throws {
        let trino = TransientConnectionFactory.build(from: try parse("trino://trino.example.com:8080/hive/sales"))

        #expect(trino.additionalFields["trinoSchema"] == "sales")
    }
}
