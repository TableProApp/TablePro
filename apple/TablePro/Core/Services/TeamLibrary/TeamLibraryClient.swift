//
//  TeamLibraryClient.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

internal enum TeamLibraryFailure: Error, Equatable, Sendable {
    case offline
    case rateLimited
    case server
    case signedOut
    // No seat, the team's plan lacks team_library, or the team is gone: the library is not this account's to read.
    case unreadable
    case writeForbidden
    case cursorExpired
    // The server refused the push as sent (422, 413); sending it again changes nothing. Names the refused item when
    // the server points at one.
    case refused(String?)

    // The case alone: a refusal carries the name of someone's saved item.
    var logName: String {
        switch self {
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .server: "server"
        case .signedOut: "signedOut"
        case .unreadable: "unreadable"
        case .writeForbidden: "writeForbidden"
        case .cursorExpired: "cursorExpired"
        case .refused: "refused"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .server:
            return true
        case .signedOut, .unreadable, .writeForbidden, .cursorExpired, .refused:
            return false
        }
    }

    static func from(_ error: AccountError) -> TeamLibraryFailure {
        switch error {
        case .signedOut:
            return .signedOut
        case .server(let status, _) where status == 401:
            return .signedOut
        case .server(let status, _) where status == 429:
            return .rateLimited
        case .server(let status, _) where status >= 500:
            return .server
        case .server:
            return .refused(nil)
        default:
            return .offline
        }
    }
}

internal struct TeamLibraryPage: Sendable {
    let changes: [TeamLibraryChange]
    let cursor: String
    let hasMore: Bool
}

internal enum TeamLibraryPushAnswer: Sendable {
    case results([Components.Schemas.LibraryResult])
    // A 422 naming one change by its place in the batch: the server applied none of the batch.
    case refusedChange(Int)
}

// The /v2 team library calls through the generated client, which carries the session's access token.
internal struct TeamLibraryClient: Sendable {
    static let pageSize: Int64 = 500

    let api: any APIProtocol

    func pull(teamID: String, cursor: String?) async throws(TeamLibraryFailure) -> TeamLibraryPage {
        do {
            switch try await api.listLibraryChanges(
                path: .init(teamId: teamID),
                query: .init(cursor: cursor, limit: Self.pageSize)
            ) {
            case .ok(let answer):
                let body = try answer.body.json
                return TeamLibraryPage(changes: body.changes, cursor: body.cursor, hasMore: body.hasMore)
            case .unauthorized:
                throw TeamLibraryFailure.signedOut
            case .forbidden, .notFound:
                throw TeamLibraryFailure.unreadable
            case .gone, .unprocessableContent:
                throw TeamLibraryFailure.cursorExpired
            case .tooManyRequests:
                throw TeamLibraryFailure.rateLimited
            case .internalServerError:
                throw TeamLibraryFailure.server
            case .undocumented(let status, _):
                throw Self.undocumented(status)
            }
        } catch let failure as TeamLibraryFailure {
            throw failure
        } catch {
            throw TeamLibraryFailure.from(AccountError.from(error))
        }
    }

    func push(teamID: String, edits: [TeamLibraryEdit]) async throws(TeamLibraryFailure) -> TeamLibraryPushAnswer {
        do {
            switch try await api.pushLibraryChanges(
                path: .init(teamId: teamID),
                body: .json(.init(changes: edits))
            ) {
            case .ok(let answer):
                // The answer's cursor is never adopted: it covers other writers' commits too.
                return .results(try answer.body.json.results)
            case .unauthorized:
                throw TeamLibraryFailure.signedOut
            case .forbidden(let answer):
                let problem = try answer.body.applicationProblemJson
                throw problem.code == "library_write_forbidden" ? TeamLibraryFailure.writeForbidden : .unreadable
            case .notFound:
                throw TeamLibraryFailure.unreadable
            case .contentTooLarge:
                throw TeamLibraryFailure.refused(nil)
            case .unprocessableContent(let answer):
                let problem = try answer.body.applicationProblemJson
                guard let index = Self.changeIndex(in: problem.errors?.first?.location) else {
                    throw TeamLibraryFailure.refused(nil)
                }
                return .refusedChange(index)
            case .tooManyRequests:
                throw TeamLibraryFailure.rateLimited
            case .internalServerError:
                throw TeamLibraryFailure.server
            case .undocumented(let status, _):
                throw Self.undocumented(status)
            }
        } catch let failure as TeamLibraryFailure {
            throw failure
        } catch {
            throw TeamLibraryFailure.from(AccountError.from(error))
        }
    }

    // "body.changes[3].data.password" names change 3.
    static func changeIndex(in location: String?) -> Int? {
        guard let location, location.hasPrefix("body.changes["),
              let close = location.firstIndex(of: "]")
        else { return nil }
        return Int(location[location.index(location.startIndex, offsetBy: "body.changes[".count)..<close])
    }

    private static func undocumented(_ status: Int) -> TeamLibraryFailure {
        switch status {
        case 429: .rateLimited
        case 500...: .server
        default: .refused(nil)
        }
    }
}
