//
//  CloudShareService.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

// publicAPI carries no bearer: a signed-out recipient opens a shared link too.
internal struct CloudShareService: ShareService {
    private static let pageSize: Int64 = 200
    private static let maxPages = 5

    let api: any APIProtocol
    let publicAPI: any APIProtocol
    let createRequest: ShareCreateRequest

    func limits() async throws(ShareFailure) -> ShareLimits {
        do {
            switch try await api.getShareLimits() {
            case .ok(let answer):
                return Self.limits(try answer.body.json)
            case .unauthorized(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .tooManyRequests(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .internalServerError(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .undocumented(let status, _):
                throw ShareFailure.httpStatus(status)
            }
        } catch {
            throw Self.failure(from: error)
        }
    }

    func create(_ draft: ShareDraft) async throws(ShareFailure) -> CreatedShare {
        let answer: (status: Int, contentType: String?, body: Data)
        do {
            answer = try await createRequest.send(ShareBodyWriter.body(draft))
        } catch {
            throw Self.failure(from: error)
        }
        guard answer.status == 201 else {
            let problem = try? JSONDecoder().decode(ProblemCode.self, from: answer.body)
            throw ShareFailure.problem(status: answer.status, code: problem?.code)
        }
        guard let created = try? JSONDecoder().decode(CreatedLink.self, from: answer.body),
              let url = URL(string: created.url)
        else { throw ShareFailure.server }
        return CreatedShare(id: created.share.id, url: url)
    }

    func liveLinks(teamID: String?) async throws(ShareFailure) -> [ShareLink] {
        var links: [ShareLink] = []
        var cursor: String?
        var pages = 0
        do {
            repeat {
                pages += 1
                switch try await api.listShares(query: .init(
                    team: teamID, state: .live, cursor: cursor, limit: Self.pageSize
                )) {
                case .ok(let answer):
                    let page = try answer.body.json
                    links += page.data.map(Self.link)
                    cursor = page.nextCursor
                case .unauthorized(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .forbidden(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .notFound(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .unprocessableContent(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .tooManyRequests(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .internalServerError(let answer):
                    throw Self.failure(try answer.body.applicationProblemJson)
                case .undocumented(let status, _):
                    throw ShareFailure.httpStatus(status)
                }
            } while cursor != nil && pages < Self.maxPages
        } catch {
            throw Self.failure(from: error)
        }
        return links.sorted { $0.createdAt < $1.createdAt }
    }

    func revoke(id: String) async throws(ShareFailure) {
        do {
            switch try await api.deleteShare(path: .init(shareId: id)) {
            case .noContent:
                return
            case .unauthorized(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .notFound(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .unprocessableContent(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .tooManyRequests(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .internalServerError(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .undocumented(let status, _):
                throw ShareFailure.httpStatus(status)
            }
        } catch {
            throw Self.failure(from: error)
        }
    }

    func fetchShared(token: String, password: String?) async throws(ShareFailure) -> SharedQuery {
        do {
            switch try await publicAPI.getShared(path: .init(token: token), headers: .init(xSharePassword: password)) {
            case .ok(let answer):
                let shared = try answer.body.json
                return SharedQuery(kind: ShareKind(rawValue: shared.kind) ?? .query, title: shared.title, sql: shared.sql)
            case .unauthorized(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .notFound(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .unprocessableContent:
                throw ShareFailure.notFound
            case .tooManyRequests(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .internalServerError(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .undocumented(let status, _):
                throw ShareFailure.httpStatus(status)
            }
        } catch {
            throw Self.failure(from: error)
        }
    }

    // MARK: - Mapping

    static func limits(_ wire: Components.Schemas.ShareLimits) -> ShareLimits {
        let expiries = wire.expiries.compactMap(ShareExpiry.init(rawValue:))
        return ShareLimits(
            plan: SharePlan(rawValue: wire.plan) ?? .free,
            live: Int(wire.live),
            liveLimit: Int(wire.liveLimit),
            maxRows: Int(wire.maxRows),
            expiries: expiries,
            defaultExpiry: ShareExpiry(rawValue: wire.defaultExpiry) ?? expiries.last ?? .thirtyDays,
            allowsPassword: wire.password,
            allowsDisablingDownload: wire.disableDownload,
            allowsTeamLinks: wire.team,
            emailVerified: wire.emailVerified,
            sharingDisabled: wire.sharingDisabled,
            teams: wire.teams.map { team in
                ShareTeam(
                    id: team.id,
                    name: team.name,
                    live: Int(team.live),
                    liveLimit: Int(team.liveLimit),
                    allowsPublicLinks: team.publicLinks
                )
            }
        )
    }

    static func link(_ view: Components.Schemas.ShareView) -> ShareLink {
        ShareLink(
            id: view.id,
            title: view.title,
            kind: ShareKind(rawValue: view.kind) ?? .query,
            createdAt: view.createdAt,
            expiresAt: view.expiresAt,
            isSuspended: view.suspended
        )
    }

    private static func failure(_ problem: Components.Schemas.Problem) -> ShareFailure {
        ShareFailure.problem(status: Int(problem.status), code: problem.code)
    }

    // Only a URL load that did not finish is offline; anything else that is not the server's answer is the app's.
    static func failure(from error: any Error) -> ShareFailure {
        switch error {
        case let failure as ShareFailure:
            return failure
        case let error as ClientError:
            return failure(from: error.underlyingError)
        case let error as AccountError:
            return ShareFailure.from(error)
        case is CancellationError:
            return .canceled
        case let error as URLError:
            return error.code == .cancelled ? .canceled : .offline
        default:
            return .server
        }
    }
}

private struct ProblemCode: Decodable {
    let code: String?
}

private struct CreatedLink: Decodable {
    struct Share: Decodable {
        let id: String
    }

    let share: Share
    let url: String
}
