//
//  DeviceRegistry.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

extension AccountError {
    static func problem(_ problem: Components.Schemas.Problem) -> AccountError {
        .server(status: Int(problem.status), code: problem.code)
    }

    // The generated client wraps what a middleware or the transport throws.
    static func from(_ error: any Error) -> AccountError {
        switch error {
        case let error as AccountError:
            return error
        case let error as ClientError:
            return from(error.underlyingError)
        case is CancellationError:
            return .canceled
        case let error as URLError where error.code == .cancelled:
            return .canceled
        default:
            return .network(error.localizedDescription)
        }
    }

    var problemCode: String? {
        guard case .server(_, let code) = self else { return nil }
        return code
    }
}

internal struct DeviceRegistry: Sendable {
    private static let pageSize: Int64 = 200

    let api: any APIProtocol
    let machine: MachineDescription

    // Binds the session's refresh token family to this machine's device.
    func register() async throws(AccountError) -> Components.Schemas.Device {
        let registration = Components.Schemas.DeviceRegistration(
            appVersion: machine.appVersion,
            machineId: machine.machineID,
            name: machine.name,
            osVersion: machine.osVersion,
            platform: .macos
        )
        do {
            switch try await api.registerDevice(body: .json(registration)) {
            case .ok(let answer):
                return try answer.body.json
            case .created(let answer):
                return try answer.body.json
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
    }

    func list() async throws(AccountError) -> [Components.Schemas.Device] {
        var devices: [Components.Schemas.Device] = []
        var cursor: String?
        do {
            repeat {
                switch try await api.listDevices(query: .init(limit: Self.pageSize, cursor: cursor)) {
                case .ok(let answer):
                    let page = try answer.body.json
                    devices += page.data
                    cursor = page.nextCursor
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
            } while cursor != nil
        } catch {
            throw AccountError.from(error)
        }
        return devices
    }

    func remove(deviceID: String) async throws(AccountError) {
        do {
            switch try await api.deleteDevice(path: .init(deviceId: deviceID)) {
            case .noContent:
                return
            case .unauthorized(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .notFound(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .conflict(let answer):
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
    }
}
