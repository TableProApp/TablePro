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
    case rateLimited
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

    // The message a create flow (a favorite, a result) shows, or nil when there is nothing to say.
    var createMessage: String? {
        switch self {
        case .canceled:
            return nil
        case .featureRequired:
            return String(localized: "Sharing links needs a paid plan.")
        case .signedOut:
            return String(localized: "Sign in to your account to share links.")
        case .limitReached:
            return String(localized: "You've reached your share limit. Revoke a link and try again.")
        case .offline:
            return String(localized: "You appear to be offline. Try again once you're connected.")
        case .rateLimited:
            return String(localized: "Too many shares just now. Try again in a moment.")
        case .forbidden, .notFound, .refused, .server:
            return String(localized: "The link couldn't be created. Try again.")
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
            return .rateLimited
        case .server(let status, _) where status >= 500:
            return .server
        case .server:
            return .refused
        case .network:
            return .offline
        default:
            // An OAuth, decode, or state error is not "offline"; treat it as a server-side problem.
            return .server
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
        try await create(body: .init(dialect: dialect, kind: "query", note: note, sql: sql, title: title))
    }

    func createResult(
        title: String,
        sql: String,
        note: String?,
        dialect: String?,
        snapshot: Components.Schemas.SnapshotInput
    ) async throws(ShareFailure) -> CreatedShareLink {
        try await create(body: .init(dialect: dialect, kind: "result", note: note, snapshot: snapshot, sql: sql, title: title))
    }

    private func create(body: Components.Schemas.CreateShareBody) async throws(ShareFailure) -> CreatedShareLink {
        do {
            switch try await api.createShare(body: .json(body)) {
            case .ok(let answer):
                let created = try answer.body.json
                return CreatedShareLink(id: created.id, token: created.token, url: created.url)
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
                throw ShareFailure.rateLimited
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
                throw ShareFailure.rateLimited
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

    private static func undocumented(_ status: Int) -> ShareFailure {
        switch status {
        case 429: .rateLimited
        case 500...: .server
        default: .refused
        }
    }
}
