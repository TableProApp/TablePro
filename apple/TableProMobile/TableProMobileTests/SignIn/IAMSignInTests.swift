import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct IAMSignInTests {
    @Test("MySQL and PostgreSQL offer AWS and Google Cloud IAM, signing RDS tokens", arguments: [DatabaseType.mysql, .postgresql])
    func rdsWithGoogleCloud(type: DatabaseType) throws {
        let engine = try #require(IAMSignIn.engine(for: type))

        #expect(engine.methods == [.awsAccessKey, .awsProfile, .awsSSO, .googleApplicationDefault, .googleServiceAccount])
        #expect(engine.awsService == .rds)
    }

    @Test("MariaDB offers AWS IAM only")
    func mariaDBIsAWSOnly() throws {
        let engine = try #require(IAMSignIn.engine(for: .mariadb))

        #expect(engine.methods == [.awsAccessKey, .awsProfile, .awsSSO])
        #expect(engine.awsService == .rds)
    }

    @Test("Redis offers AWS IAM and signs for its ElastiCache cache name")
    func redisSignsElastiCache() throws {
        let engine = try #require(IAMSignIn.engine(for: .redis))

        #expect(engine.methods == [.awsAccessKey, .awsProfile, .awsSSO])
        #expect(engine.awsService == .elastiCache)
    }

    @Test(
        "Every other engine offers no IAM sign-in",
        arguments: [DatabaseType.tidb, .oceanbase, .redshift, .mssql, .oracle, .sqlite, .duckdb]
    )
    func otherEnginesOfferNone(type: DatabaseType) {
        #expect(IAMSignIn.engine(for: type) == nil)
        #expect(IAMSignIn.methods(for: type).isEmpty)
    }

    @Test("The picker value parses as the Mac's does", arguments: [
        (nil, nil),
        ("", nil),
        ("off", nil),
        ("accessKey", IAMSignIn.awsAccessKey),
        ("profile", .awsProfile),
        ("sso", .awsSSO),
        ("gcpApplicationDefault", .googleApplicationDefault),
        ("gcpServiceAccount", .googleServiceAccount),
        ("somethingNewer", .awsAccessKey)
    ] as [(String?, IAMSignIn?)])
    func parsesPickerValue(value: String?, expected: IAMSignIn?) {
        #expect(IAMSignIn(pickerValue: value) == expected)
    }

    @Test("Each method writes back the picker value it was read from", arguments: IAMSignIn.allCases)
    func pickerValueRoundTrips(method: IAMSignIn) {
        #expect(IAMSignIn(pickerValue: method.pickerValue) == method)
    }

    @Test("The picker values are the Mac's Authentication options")
    func pickerValuesMatchPluginKit() throws {
        let picker = try #require(GoogleCloudSQLAuthFields.standardWithAWS().first { $0.id == IAMSignIn.Field.method })
        guard case .dropdown(let options) = picker.fieldType else {
            Issue.record("The Authentication field is not a picker")
            return
        }
        let macValues = options.map(\.value)
        let iOSValues = [IAMSignIn.passwordPickerValue] + IAMSignIn.allCases.map(\.pickerValue)

        #expect(macValues == iOSValues)
    }

    @Test("The field ids are the ones the Mac declares")
    func fieldIdsMatchPluginKit() {
        let ids = Set(GoogleCloudSQLAuthFields.standardWithAWS().map(\.id))

        #expect(ids.isSuperset(of: [
            IAMSignIn.Field.method,
            IAMSignIn.Field.region,
            IAMSignIn.Field.accessKeyId,
            IAMSignIn.Field.profileName
        ]))
        #expect(AWSAuthFields.rdsEndpointField().id == IAMSignIn.Field.rdsEndpoint)
        #expect(AWSAuthFields.elastiCacheReplicationGroupField().id == IAMSignIn.Field.replicationGroupId)
    }

    @Test("The Mac's secure fields are read under the names the Mac stores them by")
    func secureFieldsMatchSecretKinds() {
        let macAccounts = GoogleCloudSQLAuthFields.standardWithAWS().filter { $0.isSecure }.map { "com.TablePro.plugin.\($0.id)." }
        let kinds: [ConnectionSecretKind] = [.awsSecretAccessKey, .awsSessionToken, .gcpServiceAccountKey]
        let iOSAccounts = kinds.map(\.prefix)

        #expect(macAccounts == iOSAccounts)
    }

    @Test("A connection signs in with the method its engine offers")
    func connectionReadsItsMethod() {
        let connection = DatabaseConnection(type: .postgresql, additionalFields: ["awsAuth": "gcpServiceAccount"])

        #expect(connection.iamSignIn == .googleServiceAccount)
    }

    @Test("An engine without IAM ignores a synced awsAuth", arguments: [DatabaseType.redshift, .tidb, .oceanbase])
    func engineWithoutIAMIgnoresIt(type: DatabaseType) {
        let connection = DatabaseConnection(type: type, additionalFields: ["awsAuth": "accessKey"])

        #expect(connection.iamSignIn == nil)
    }

    @Test("A method the engine does not offer is ignored")
    func unofferedMethodIsIgnored() {
        let connection = DatabaseConnection(type: .mariadb, additionalFields: ["awsAuth": "gcpServiceAccount"])

        #expect(connection.iamSignIn == nil)
    }

    @Test("A password connection has no IAM sign-in")
    func passwordConnection() {
        #expect(DatabaseConnection(type: .mysql, additionalFields: ["awsAuth": "off"]).iamSignIn == nil)
        #expect(DatabaseConnection(type: .mysql).iamSignIn == nil)
    }
}
