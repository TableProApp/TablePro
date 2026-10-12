import Foundation

enum RDSDiscoveryError: LocalizedError, Equatable {
    case invalidRegion(region: String)
    case accessDenied(region: String)
    case expiredCredentials(region: String)
    case invalidCredentials(region: String)
    case regionNotEnabled(region: String)
    case throttled(region: String)
    case clockSkew(region: String)
    case signatureMismatch(region: String)
    case network(region: String, detail: String)
    case malformedResponse(region: String)
    case service(region: String, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidRegion(let region):
            return String(format: String(localized: "\"%@\" is not a valid AWS region."), region)
        case .accessDenied(let region):
            return String(
                format: String(
                    localized: "This profile is not allowed to run rds:DescribeDBInstances in %@. Attach AmazonRDSReadOnlyAccess or an equivalent policy."
                ),
                region
            )
        case .expiredCredentials:
            return String(localized: "The AWS credentials for this profile have expired. Sign in again and retry.")
        case .invalidCredentials:
            return String(localized: "AWS rejected these credentials. Check the profile in ~/.aws/config.")
        case .regionNotEnabled(let region):
            return String(
                format: String(localized: "The AWS region %@ is not enabled for this account."),
                region
            )
        case .throttled(let region):
            return String(format: String(localized: "AWS is throttling requests in %@. Try again shortly."), region)
        case .clockSkew:
            return String(
                localized: "AWS rejected the request signature because this Mac's clock is too far off. Check Date & Time in System Settings."
            )
        case .signatureMismatch:
            return String(localized: "AWS rejected the request signature for this profile's credentials.")
        case .network(_, let detail):
            return String(format: String(localized: "Could not reach the AWS RDS API: %@"), detail)
        case .malformedResponse(let region):
            return String(format: String(localized: "The AWS RDS API in %@ returned a response TablePro could not read."), region)
        case .service(_, let code, let message):
            return message.isEmpty ? code : "\(code): \(message)"
        }
    }

    var region: String {
        switch self {
        case .invalidRegion(let region),
             .accessDenied(let region),
             .expiredCredentials(let region),
             .invalidCredentials(let region),
             .regionNotEnabled(let region),
             .throttled(let region),
             .clockSkew(let region),
             .signatureMismatch(let region),
             .malformedResponse(let region):
            return region
        case .network(let region, _), .service(let region, _, _):
            return region
        }
    }

    var isCredentialFailure: Bool {
        switch self {
        case .expiredCredentials, .invalidCredentials:
            return true
        default:
            return false
        }
    }

    static func mapping(code: String, message: String, region: String) -> RDSDiscoveryError {
        switch code {
        case "AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "NotAuthorized",
             "MissingAuthenticationToken":
            return .accessDenied(region: region)
        case "ExpiredToken", "ExpiredTokenException", "RequestExpired", "TokenRefreshRequired":
            return .expiredCredentials(region: region)
        case "InvalidClientTokenId", "UnrecognizedClientException", "InvalidAccessKeyId", "AuthFailure":
            return .invalidCredentials(region: region)
        case "OptInRequired":
            return .regionNotEnabled(region: region)
        case "Throttling", "ThrottlingException", "RequestLimitExceeded", "TooManyRequestsException":
            return .throttled(region: region)
        case "RequestTimeTooSkewed":
            return .clockSkew(region: region)
        case "SignatureDoesNotMatch", "IncompleteSignature":
            return .signatureMismatch(region: region)
        default:
            return .service(region: region, code: code, message: message)
        }
    }
}
