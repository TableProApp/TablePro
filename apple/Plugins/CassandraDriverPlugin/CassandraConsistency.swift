import Foundation
import TableProPluginKit

enum CassandraConsistencyLevel: String, CaseIterable, Sendable {
    case any = "ANY"
    case one = "ONE"
    case two = "TWO"
    case three = "THREE"
    case quorum = "QUORUM"
    case all = "ALL"
    case localQuorum = "LOCAL_QUORUM"
    case eachQuorum = "EACH_QUORUM"
    case serial = "SERIAL"
    case localSerial = "LOCAL_SERIAL"
    case localOne = "LOCAL_ONE"

    static let serialLevels: [CassandraConsistencyLevel] = [.serial, .localSerial]

    // SERIAL and LOCAL_SERIAL refuse every plain write, so a connection never defaults to them.
    static let connectionLevels: [CassandraConsistencyLevel] = [
        .localOne, .one, .two, .three, .quorum, .localQuorum, .eachQuorum, .all, .any,
    ]

    init?(name: some StringProtocol) {
        self.init(rawValue: name.uppercased())
    }
}

// A nil serial level is never sent, and the server then applies SERIAL.
struct CassandraConsistency: Sendable, Equatable {
    static let levelFieldId = "cassandraConsistency"
    static let serialLevelFieldId = "cassandraSerialConsistency"

    var level: CassandraConsistencyLevel
    var serialLevel: CassandraConsistencyLevel?

    var effectiveSerialLevel: CassandraConsistencyLevel {
        serialLevel ?? .serial
    }

    static var connectionFields: [ConnectionField] {
        [
            ConnectionField(
                id: levelFieldId,
                label: String(localized: "Consistency"),
                fieldType: .dropdown(
                    options: [ConnectionField.DropdownOption(value: "", label: String(localized: "Default"))]
                        + CassandraConsistencyLevel.connectionLevels.map {
                            ConnectionField.DropdownOption(value: $0.rawValue, label: $0.rawValue)
                        }
                ),
                section: .advanced
            ),
            ConnectionField(
                id: serialLevelFieldId,
                label: String(localized: "Serial Consistency"),
                fieldType: .dropdown(
                    options: [ConnectionField.DropdownOption(value: "", label: String(localized: "Default"))]
                        + CassandraConsistencyLevel.serialLevels.map {
                            ConnectionField.DropdownOption(value: $0.rawValue, label: $0.rawValue)
                        }
                ),
                section: .advanced
            ),
        ]
    }

    init(level: CassandraConsistencyLevel, serialLevel: CassandraConsistencyLevel? = nil) {
        self.level = level
        self.serialLevel = serialLevel
    }

    // Amazon Keyspaces refuses a write at any level but LOCAL_QUORUM, so an unset level there is LOCAL_QUORUM.
    init(additionalFields: [String: String], host: String) throws {
        let storedLevel = Self.storedValue(additionalFields[Self.levelFieldId])
        let storedSerialLevel = Self.storedValue(additionalFields[Self.serialLevelFieldId])

        if let storedLevel {
            guard let level = CassandraConsistencyLevel(name: storedLevel),
                  CassandraConsistencyLevel.connectionLevels.contains(level) else {
                throw CassandraPluginError.connectionFailed(String(
                    format: String(localized: "%@ is not a consistency level this connection can use. Pick one in the connection's Consistency setting."),
                    storedLevel
                ))
            }
            self.level = level
        } else {
            self.level = Self.isAmazonKeyspaces(host: host, additionalFields: additionalFields) ? .localQuorum : .localOne
        }

        if let storedSerialLevel {
            guard let serialLevel = CassandraConsistencyLevel(name: storedSerialLevel),
                  CassandraConsistencyLevel.serialLevels.contains(serialLevel) else {
                throw CassandraPluginError.connectionFailed(String(
                    format: String(localized: "%@ is not a serial consistency level. Use SERIAL or LOCAL_SERIAL."),
                    storedSerialLevel
                ))
            }
            self.serialLevel = serialLevel
        } else {
            self.serialLevel = nil
        }
    }

    static func isAmazonKeyspaces(host: String, additionalFields: [String: String]) -> Bool {
        let awsAuth = additionalFields["awsAuth"] ?? "off"
        if !awsAuth.isEmpty, awsAuth != "off" { return true }
        // Through an SSH tunnel the host is the forward's loopback address, and the endpoint stays in preTunnelHost.
        let endpoint = additionalFields["preTunnelHost"].flatMap { $0.isEmpty ? nil : $0 } ?? host
        let name = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.range(of: keyspacesEndpointPattern, options: .regularExpression) != nil
    }

    // cassandra[-fips].<region> on amazonaws.com[.cn] or api.aws, and vpce-<id>.cassandra.<region>.vpce.amazonaws.com.
    private static let keyspacesEndpointPattern =
        #"(^|\.)cassandra(-fips)?\.[a-z0-9-]+\.(amazonaws\.com(\.cn)?|api\.aws|vpce\.amazonaws\.com)$"#

    func statusMessage(columns: [String]) -> String {
        guard columns.first == CassandraRowWriter.unappliedMarker else {
            return String(format: String(localized: "Consistency: %@"), level.rawValue)
        }
        return String(
            format: String(localized: "Consistency: %1$@, serial: %2$@"),
            level.rawValue,
            effectiveSerialLevel.rawValue
        )
    }

    private static func storedValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
