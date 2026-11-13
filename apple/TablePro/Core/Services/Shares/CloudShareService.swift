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
    // The contract's maxLength for a column's name and its type.
    private static let columnTextLimit = 256

    let api: any APIProtocol
    let publicAPI: any APIProtocol

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
        do {
            switch try await api.createShare(body: .json(Self.body(draft))) {
            case .created(let answer):
                let created = try answer.body.json
                guard let url = URL(string: created.url) else { throw ShareFailure.server }
                return CreatedShare(id: created.share.id, url: url)
            case .unauthorized(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .notFound(let answer):
                throw Self.failure(try answer.body.applicationProblemJson)
            case .conflict(let answer):
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

    func liveLinks() async throws(ShareFailure) -> [ShareLink] {
        var links: [ShareLink] = []
        var cursor: String?
        var pages = 0
        do {
            repeat {
                pages += 1
                switch try await api.listShares(query: .init(state: .live, cursor: cursor, limit: Self.pageSize)) {
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
            sharingDisabled: wire.sharingDisabled
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

    static func body(_ draft: ShareDraft) -> Components.Schemas.CreateShareBody {
        Components.Schemas.CreateShareBody(
            allowDownload: draft.allowsDownload,
            dialect: draft.dialect.map { String($0.prefix(40)) },
            expiry: expiry(draft.expiry),
            hideSql: draft.hidesSQL,
            kind: draft.kind == .result ? .result : .query,
            note: draft.note,
            password: draft.password,
            snapshot: draft.snapshot.map(snapshot),
            sql: draft.sql,
            title: draft.title.isEmpty ? nil : draft.title
        )
    }

    static func expiry(_ expiry: ShareExpiry) -> Components.Schemas.ShareExpiry {
        switch expiry {
        case .oneDay: ._1d
        case .sevenDays: ._7d
        case .thirtyDays: ._30d
        case .never: .never
        }
    }

    static func snapshot(_ snapshot: ShareSnapshot) -> Components.Schemas.SnapshotBody {
        Components.Schemas.SnapshotBody(
            columns: snapshot.columns.map { column in
                Components.Schemas.SnapshotColumnBody(
                    name: clipped(column.name),
                    _type: column.type.map(clipped)
                )
            },
            rowCount: snapshot.isTruncated ? Int64(snapshot.rowCount) : nil,
            rows: snapshot.rows.map { $0.map(value) }
        )
    }

    // The server counts maxLength in Unicode scalars, not Characters.
    private static func clipped(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(columnTextLimit)))
    }

    static func value(_ cell: ShareCell) -> OpenAPIValueContainer {
        switch cell {
        case .null: OpenAPIValueContainer(nilLiteral: ())
        case .bool(let flag): OpenAPIValueContainer(booleanLiteral: flag)
        case .integer(let number): OpenAPIValueContainer(integerLiteral: Int(number))
        case .double(let number): OpenAPIValueContainer(floatLiteral: number)
        case .string(let text): OpenAPIValueContainer(stringLiteral: text)
        }
    }

    private static func failure(_ problem: Components.Schemas.Problem) -> ShareFailure {
        ShareFailure.problem(status: Int(problem.status), code: problem.code)
    }

    private static func failure(from error: any Error) -> ShareFailure {
        if let failure = error as? ShareFailure {
            return failure
        }
        return ShareFailure.from(AccountError.from(error))
    }
}
