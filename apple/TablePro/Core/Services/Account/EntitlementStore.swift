//
//  EntitlementStore.swift
//  TablePro
//

import Foundation
import os
import TableProCloudAPI

internal enum EntitlementFetchResult: Equatable, Sendable {
    case issued(Entitlement)
    case deviceLimitReached([Components.Schemas.LicensedDevice])
}

// The entitlement token lives in a file: it is signed, not secret, and checked again on every read.
internal struct EntitlementStore: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EntitlementStore")

    let fileURL: URL
    let verifier: EntitlementVerifier
    let machine: MachineDescription
    let now: @Sendable () -> Date

    // Keeps a token whose time has passed, so the app can say what lapsed; drops one that fails anything else.
    func load() -> Entitlement? {
        guard let data = try? Data(contentsOf: fileURL), let text = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try verifier.verifySignature(token, machineID: machine.machineID)
        } catch {
            Self.logger.error("Dropping the stored entitlement: \(error.publicLogShape, privacy: .public)")
            clear()
            return nil
        }
    }

    func save(_ entitlement: Entitlement) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(entitlement.token.utf8).write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // A tablepro-offline-*.jwt file holds the token itself and passes the same checks as one from the API.
    func readOfflineFile(at url: URL) throws(AccountError) -> Entitlement {
        guard let data = try? Data(contentsOf: url), let text = String(bytes: data, encoding: .utf8) else {
            throw .invalidResponse
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try verifier.verify(token, machineID: machine.machineID, now: now())
        } catch {
            throw .entitlementRejected(error)
        }
    }

    func fetch(api: any APIProtocol, deviceID: String) async throws(AccountError) -> EntitlementFetchResult {
        let request = Components.Schemas.EntitlementRequest(appVersion: machine.appVersion, osVersion: machine.osVersion)
        let token: String
        do {
            switch try await api.issueEntitlement(path: .init(deviceId: deviceID), body: .json(request)) {
            case .ok(let answer):
                token = try answer.body.json.token
            case .conflict(let answer):
                let problem = try answer.body.applicationProblemJson
                guard problem.code == "device_limit_reached" else {
                    throw AccountError.server(status: Int(problem.status), code: problem.code)
                }
                return .deviceLimitReached(problem.devices)
            case .unauthorized(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .unprocessableContent(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .tooManyRequests(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .internalServerError(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .undocumented(let status, _):
                throw AccountError.server(status: status, code: nil)
            }
        } catch {
            throw AccountError.from(error)
        }
        do {
            return .issued(try verifier.verify(token, machineID: machine.machineID, now: now()))
        } catch {
            throw .entitlementRejected(error)
        }
    }
}
