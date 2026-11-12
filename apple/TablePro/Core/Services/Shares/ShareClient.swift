//
//  ShareClient.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

internal enum ShareFailure: Error, Equatable, Sendable {
    case offline
    // The request was cancelled (torn down, superseded). Nothing to tell the user.
    case canceled
    // The 429's Retry-After, when it carried one.
    case rateLimited(retryAfter: Duration?)
    case server
    case signedOut
    // The account's plan does not include shared_links.
    case featureRequired
    // A team share without a seat, or a share not the caller's to manage.
    case forbidden
    // Unknown, revoked, or expired.
    case notFound
    // The account holds its live-share cap.
    case limitReached
    // The server refused the request as sent (422); sending it again changes nothing.
    case refused

    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .server:
            return true
        case .canceled, .signedOut, .featureRequired, .forbidden, .notFound, .limitReached, .refused:
            return false
        }
    }

    static func from(_ error: AccountError) -> ShareFailure {
        switch error {
        case .canceled:
            return .canceled
        case .signedOut:
            return .signedOut
        case .server(let status, _) where status == 401:
            return .signedOut
        case .server(let status, _) where status == 429:
            return .rateLimited(retryAfter: nil)
        case .server(let status, _) where status >= 500:
            return .server
        case .server:
            return .refused
        default:
            return .offline
        }
    }
}

internal struct CreatedShareLink: Sendable {
    let id: String
    let token: String
    let url: String
}

// The /v2 share calls go through the generated client, which carries the session's access token. The public read
// needs no token, but sending one is harmless.
internal struct ShareClient: Sendable {
    let api: any APIProtocol

    func createQuery(title: String, sql: String, note: String?, dialect: String?) async throws(ShareFailure) -> CreatedShareLink {
        do {
            switch try await api.createShare(body: .json(.init(dialect: dialect, kind: "query", note: note, sql: sql, title: title))) {
            case .ok(let answer):
                let body = try answer.body.json
                return CreatedShareLink(id: body.id, token: body.token, url: body.url)
            case .unauthorized:
                throw ShareFailure.signedOut
            case .forbidden(let answer):
                let problem = try answer.body.applicationProblemJson
                throw problem.code == "feature_required" ? ShareFailure.featureRequired : .forbidden
            case .notFound:
                throw ShareFailure.notFound
            case .conflict:
                throw ShareFailure.limitReached
            case .unprocessableContent:
                throw ShareFailure.refused
            case .tooManyRequests(let answer):
                throw ShareFailure.rateLimited(retryAfter: Self.delay(seconds: answer.headers.retryAfter))
            case .internalServerError:
                throw ShareFailure.server
            case .undocumented(let status, _):
                throw Self.undocumented(status)
            }
        } catch let failure as ShareFailure {
            throw failure
        } catch {
            throw ShareFailure.from(AccountError.from(error))
        }
    }

    func view(token: String) async throws(ShareFailure) -> Components.Schemas.PublicShare {
        do {
            switch try await api.getShared(path: .init(token: token)) {
            case .ok(let answer):
                return try answer.body.json
            case .notFound, .unprocessableContent:
                throw ShareFailure.notFound
            case .tooManyRequests(let answer):
                throw ShareFailure.rateLimited(retryAfter: Self.delay(seconds: answer.headers.retryAfter))
            case .internalServerError:
                throw ShareFailure.server
            case .undocumented(let status, _):
                throw Self.undocumented(status)
            }
        } catch let failure as ShareFailure {
            throw failure
        } catch {
            throw ShareFailure.from(AccountError.from(error))
        }
    }

    private static func delay(seconds: Int?) -> Duration? {
        guard let seconds, seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    private static func undocumented(_ status: Int) -> ShareFailure {
        switch status {
        case 429: .rateLimited(retryAfter: nil)
        case 500...: .server
        default: .refused
        }
    }
}
