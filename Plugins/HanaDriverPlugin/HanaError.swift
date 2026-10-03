import Foundation
import TableProPluginKit

struct HanaError: PluginDriverError, Equatable {
    enum Kind: Equatable, Sendable {
        case server
        case cancelled
        case timeout
        case connectionLost
        case closed
        case parameter
        case configuration
        case connect
        case missingObject
        case invalidResult
        case internalFailure
    }

    let kind: Kind
    let message: String
    let code: Int?
    let detail: String?

    init(kind: Kind, message: String, code: Int? = nil, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.detail = detail
    }

    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { code }
    var pluginErrorDetail: String? { detail }

    static var closed: HanaError {
        HanaError(kind: .closed, message: String(localized: "The SAP HANA connection is closed."))
    }

    static var connectionLost: HanaError {
        HanaError(kind: .connectionLost, message: String(localized: "Lost connection to the SAP HANA server."))
    }

    static var unreadableResult: HanaError {
        HanaError(
            kind: .invalidResult,
            message: String(localized: "SAP HANA returned a result TablePro could not read.")
        )
    }
}

enum HanaFailureMapping {
    static func connectError(
        for failure: HanaBridgeFailure,
        cancellationRequested: Bool,
        timeoutSeconds: Double = HanaConnectConfiguration.defaultConnectTimeoutSeconds
    ) -> any Error {
        guard failure.kind == .timeout else {
            return error(for: failure, cancellationRequested: cancellationRequested)
        }
        return HanaError(
            kind: .connect,
            message: String(
                format: String(localized: "TablePro could not reach the SAP HANA server within %lld seconds."),
                Int64(timeoutSeconds.rounded(.up))
            )
        )
    }

    static func error(for failure: HanaBridgeFailure, cancellationRequested: Bool) -> any Error {
        switch failure.kind {
        case .cancelled:
            guard !cancellationRequested else { return CancellationError() }
            return HanaError(kind: .cancelled, message: String(localized: "The SAP HANA statement was cancelled."))
        case .server:
            return serverError(failure)
        case .timeout:
            return HanaError(
                kind: .timeout,
                message: String(localized: "The statement ran longer than the query timeout and was stopped.")
            )
        case .connectionLost:
            return HanaError(
                kind: .connectionLost,
                message: HanaError.connectionLost.message,
                detail: nonEmpty(failure.message)
            )
        case .closed:
            return HanaError.closed
        case .parameter:
            return HanaError(kind: .parameter, message: parameterMessage(failure))
        case .tls:
            return tlsError(failure)
        case .configuration:
            return HanaError(
                kind: .configuration,
                message: String(localized: "The SAP HANA connection settings are not valid."),
                detail: nonEmpty(failure.message)
            )
        case .connect:
            return HanaError(
                kind: .connect,
                message: String(localized: "TablePro could not reach the SAP HANA server."),
                detail: nonEmpty(failure.message)
            )
        case .internalFailure:
            return HanaError(
                kind: .internalFailure,
                message: String(localized: "The SAP HANA driver failed unexpectedly."),
                detail: nonEmpty(failure.message)
            )
        }
    }

    private static func serverError(_ failure: HanaBridgeFailure) -> HanaError {
        let message = nonEmpty(failure.message) ?? String(localized: "SAP HANA reported an error.")
        return HanaError(kind: .server, message: message, code: failure.code == 0 ? nil : failure.code)
    }

    private static func tlsError(_ failure: HanaBridgeFailure) -> SSLHandshakeError {
        let serverMessage = failure.message
        switch HanaBridgeFailure.TLSCode(rawValue: failure.code) {
        case .untrustedCertificate:
            return .untrustedCertificate(serverMessage: serverMessage)
        case .hostnameMismatch:
            return .hostnameMismatch(serverMessage: serverMessage)
        case .serverRequiresPlaintext:
            return .serverRequiresPlaintext(serverMessage: serverMessage)
        case .clientCredentialsUnreadable:
            return .clientKeyInvalid(serverMessage: serverMessage)
        case nil:
            return .unknown(serverMessage: serverMessage)
        }
    }

    private static func parameterMessage(_ failure: HanaBridgeFailure) -> String {
        let position = Int64(failure.parameter)
        let value = failure.message
        switch failure.expected {
        case "date":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a date. SAP HANA expects YYYY-MM-DD."),
                position, value
            )
        case "time":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a time. SAP HANA expects HH:MM:SS."),
                position, value
            )
        case "seconddate":
            return String(
                format: String(
                    localized: "Value %1$lld, \"%2$@\", is not a date and time. SAP HANA expects YYYY-MM-DD HH:MM:SS."
                ),
                position, value
            )
        case "timestamp":
            return String(
                format: String(
                    localized: "Value %1$lld, \"%2$@\", is not a timestamp. SAP HANA expects YYYY-MM-DD HH:MM:SS.FFFFFFF."
                ),
                position, value
            )
        case "boolean":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a boolean. SAP HANA expects TRUE or FALSE."),
                position, value
            )
        case "integer":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a whole number."),
                position, value
            )
        case "decimal":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a decimal number."),
                position, value
            )
        case "double":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", is not a number."),
                position, value
            )
        case "hex":
            return String(
                format: String(
                    localized: "Value %1$lld, \"%2$@\", is not hex-encoded well-known binary, the form SAP HANA takes for a spatial value."
                ),
                position, value
            )
        case "output":
            return String(
                format: String(localized: "Parameter %lld is an OUT parameter, which TablePro cannot bind."),
                position
            )
        case "scale":
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", has more decimal places than the column allows."),
                position, value
            )
        default:
            return String(
                format: String(localized: "Value %1$lld, \"%2$@\", could not be converted for SAP HANA."),
                position, value
            )
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
