//
//  DatabaseConnection+IAMSignIn.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A sign-in with a token that expires instead of a stored password.
enum IAMSignInMethod: Equatable, Sendable {
    /// `source` is what `AWSCredentialResolver` takes: `accessKey`, `profile` or `sso`.
    case aws(source: String)
    case googleCloud(GoogleCloudSQLCredentialKind)

    /// The Authentication picker keeps the `awsAuth` id it had before it offered Google Cloud, so
    /// this is the one place that tells its values apart.
    init?(pickerValue: String?) {
        guard let pickerValue, !pickerValue.isEmpty, pickerValue != "off",
              pickerValue != KerberosAuthFields.method else { return nil }
        switch pickerValue {
        case GoogleCloudSQLAuthFields.applicationDefault:
            self = .googleCloud(.applicationDefault)
        case GoogleCloudSQLAuthFields.serviceAccount:
            self = .googleCloud(.serviceAccount)
        default:
            self = .aws(source: pickerValue)
        }
    }
}

enum GoogleCloudSQLCredentialKind: Equatable, Sendable {
    case applicationDefault
    case serviceAccount
}

extension DatabaseConnection {
    static let iamSignInFieldId = "awsAuth"

    // Only a value the type's own Authentication picker offers. A definition from someone else can carry the field on
    // an engine that takes no IAM token, which would sign one and send it to whatever servers that engine dials. The
    // Keyspaces engines are the exception for AWS: their plugin signs in itself and this host mints nothing for them.
    var iamSignIn: IAMSignInMethod? {
        guard let value = additionalFields[Self.iamSignInFieldId],
              let method = IAMSignInMethod(pickerValue: value)
        else { return nil }
        if resolvesAWSIAMInDriver, case .aws = method {
            return method
        }
        return Self.offersSignIn(value, for: type) ? method : nil
    }

    private static func offersSignIn(_ value: String, for type: DatabaseType) -> Bool {
        let field = PluginMetadataRegistry.shared.snapshot(for: type)?.connection.additionalConnectionFields
            .first { $0.id == iamSignInFieldId }
        guard case .dropdown(let options) = field?.fieldType else { return false }
        return options.contains { $0.value == value }
    }

    var usesAWSIAM: Bool {
        if case .aws = iamSignIn { return true }
        return false
    }

    var usesGoogleCloudIAM: Bool {
        if case .googleCloud = iamSignIn { return true }
        return false
    }

    /// The token is minted for each sign-in and never cached as the session's password, because
    /// replaying it after it expires fails the next one.
    var usesIAMToken: Bool {
        iamSignIn != nil
    }

    /// The SSL a sign-in uses. A token signs in as its principal for as long as it lives, so it is
    /// never sent in plaintext: TLS is raised to Required. The Cloud SQL Auth Proxy is the exception,
    /// because its loopback listener has no TLS and the proxy encrypts the hop to the instance.
    var transportSSLConfiguration: SSLConfiguration {
        guard !localSocketSkipsTLS else { return SSLConfiguration() }
        var ssl = sslConfig
        guard usesIAMToken, !tunnelSecuresTransport, ssl.mode == .disabled || ssl.mode == .preferred else {
            return ssl
        }
        ssl.mode = .required
        return ssl
    }
}
