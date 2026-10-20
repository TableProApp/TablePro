import Foundation
import TableProModels
import TableProPluginKit

// A local copy of the Mac's IAMSignInMethod: a non-frozen PluginKit enum would force `@unknown default` into Mac switches.
nonisolated enum IAMSignIn: CaseIterable, Hashable, Identifiable, Sendable {
    case awsAccessKey
    case awsProfile
    case awsSSO
    case googleApplicationDefault
    case googleServiceAccount

    nonisolated enum AWSService: Equatable, Sendable {
        case rds
        case elastiCache
    }

    nonisolated struct Engine: Equatable, Sendable {
        let methods: [IAMSignIn]
        let awsService: AWSService
    }

    nonisolated enum Field {
        static let method = "awsAuth"
        static let region = "awsRegion"
        static let accessKeyId = "awsAccessKeyId"
        static let profileName = "awsProfileName"
        static let rdsEndpoint = "awsRDSEndpoint"
        static let replicationGroupId = "awsReplicationGroupId"
    }

    static let passwordPickerValue = "off"

    private static let aws: [IAMSignIn] = [.awsAccessKey, .awsProfile, .awsSSO]
    private static let googleCloud: [IAMSignIn] = [.googleApplicationDefault, .googleServiceAccount]

    // The field sets the Mac declares for each engine; any other type ignores its `awsAuth`.
    static func engine(for type: DatabaseType) -> Engine? {
        switch type {
        case .mysql, .postgresql:
            Engine(methods: aws + googleCloud, awsService: .rds)
        case .mariadb:
            Engine(methods: aws, awsService: .rds)
        case .redis:
            Engine(methods: aws, awsService: .elastiCache)
        default:
            nil
        }
    }

    static func methods(for type: DatabaseType) -> [IAMSignIn] {
        engine(for: type)?.methods ?? []
    }

    init?(pickerValue: String?) {
        guard let pickerValue, !pickerValue.isEmpty, pickerValue != Self.passwordPickerValue else { return nil }
        switch pickerValue {
        case GoogleCloudSQLAuthFields.applicationDefault:
            self = .googleApplicationDefault
        case GoogleCloudSQLAuthFields.serviceAccount:
            self = .googleServiceAccount
        case Self.awsProfile.pickerValue:
            self = .awsProfile
        case Self.awsSSO.pickerValue:
            self = .awsSSO
        default:
            // The Mac's credential resolver signs any other value with the access key.
            self = .awsAccessKey
        }
    }

    var id: String { pickerValue }

    var pickerValue: String {
        switch self {
        case .awsAccessKey: "accessKey"
        case .awsProfile: "profile"
        case .awsSSO: "sso"
        case .googleApplicationDefault: GoogleCloudSQLAuthFields.applicationDefault
        case .googleServiceAccount: GoogleCloudSQLAuthFields.serviceAccount
        }
    }

    var title: String {
        switch self {
        case .awsAccessKey: String(localized: "AWS IAM (Access Key)")
        case .awsProfile: String(localized: "AWS IAM (Profile)")
        case .awsSSO: String(localized: "AWS IAM (SSO)")
        case .googleApplicationDefault: String(localized: "Google Cloud IAM (Application Default)")
        case .googleServiceAccount: String(localized: "Google Cloud IAM (Service Account)")
        }
    }

    var isAWS: Bool {
        switch self {
        case .awsAccessKey, .awsProfile, .awsSSO: true
        case .googleApplicationDefault, .googleServiceAccount: false
        }
    }
}

nonisolated extension DatabaseConnection {
    var iamSignIn: IAMSignIn? {
        guard let method = IAMSignIn(pickerValue: additionalFields[IAMSignIn.Field.method]),
              IAMSignIn.methods(for: type).contains(method) else { return nil }
        return method
    }
}
