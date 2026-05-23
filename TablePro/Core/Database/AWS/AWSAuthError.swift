//
//  AWSAuthError.swift
//  TablePro
//

import Foundation

enum AWSAuthError: Error, LocalizedError, Equatable {
    case missingAccessKey
    case credentialsFileUnreadable
    case profileIncomplete(String)
    case regionUnknown(host: String)

    var errorDescription: String? {
        switch self {
        case .missingAccessKey:
            return String(localized: "Access Key ID and Secret Access Key are required for AWS IAM authentication.")
        case .credentialsFileUnreadable:
            return String(localized: "Cannot read ~/.aws/credentials.")
        case .profileIncomplete(let profile):
            return String(
                format: String(localized: "Profile \"%@\" was not found or is missing keys in ~/.aws/credentials."),
                profile
            )
        case .regionUnknown(let host):
            return String(
                format: String(localized: "Could not determine an AWS region for \"%@\". Set the AWS Region field."),
                host
            )
        }
    }
}
