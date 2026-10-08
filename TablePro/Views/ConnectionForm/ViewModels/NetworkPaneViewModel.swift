//
//  NetworkPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import Network
import TableProPluginKit

@MainActor
final class NetworkPaneViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var type: DatabaseType = .mysql
    @Published var host: String = ""
    @Published var port: String = ""
    @Published var database: String = ""
    @Published var sshForwardUnixSocketPath: String = ""
    @Published var additionalFieldValues: [String: String] = [:]

    @Published var coordinator: WeakCoordinatorRef?

    var forwardsToUnixSocket: Bool {
        !sshForwardUnixSocketPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var connectionMode: ConnectionMode {
        PluginManager.shared.connectionMode(for: type)
    }

    var connectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .connection }
    }

    var hasHostListField: Bool {
        connectionFields.contains { field in
            guard case .hostList = field.fieldType else { return false }
            return isFieldVisible(field)
        }
    }

    var defaultPort: String {
        let port = type.defaultPort
        return port == 0 ? "" : String(port)
    }

    private var firstVisibleHostListFieldId: String? {
        connectionFields.first { field in
            guard case .hostList = field.fieldType else { return false }
            return isFieldVisible(field)
        }?.id
    }

    internal var tunnelHostListCaption: String? {
        guard let fieldId = firstVisibleHostListFieldId else { return nil }
        if fieldId == "redisSentinelHosts" {
            return String(
                localized: "Sentinel mode cannot run through a tunnel. Set Connection Mode to Standalone and enter a data node, or turn the tunnel off."
            )
        }
        if fieldId == "redisClusterHosts" {
            return String(
                localized: "TablePro connects to the first node over a tunnel, as a single server. Keys on other nodes cannot be reached."
            )
        }
        guard (additionalFieldValues[fieldId] ?? "").contains(",") else { return nil }
        switch fieldId {
        case "mongoHosts":
            return String(localized: "TablePro connects to the first host over a tunnel. Replica set failover is not available.")
        case "kafkaBootstrapServers":
            return String(
                localized: "TablePro connects to the first broker over a tunnel. Partitions led by other brokers cannot be read."
            )
        default:
            return String(localized: "TablePro connects to the first host over a tunnel. The other hosts are not used.")
        }
    }

    var socketPathPrompt: String {
        PluginManager.shared.defaultUnixSocketPath(for: type) ?? "/path/to/database.sock"
    }

    var resolvedHost: String {
        host.trimmingCharacters(in: .whitespaces).isEmpty ? (type.defaultHost ?? "localhost") : host
    }

    var resolvedPort: Int {
        Int(port) ?? type.defaultPort
    }

    /// Kerberos service principals are not registered against IP addresses, so SQL Server's
    /// Windows Authentication warns when the host is one.
    var resolvedHostIsIPAddress: Bool {
        let host = resolvedHost.trimmingCharacters(in: .whitespaces)
        return IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    var hidesBuiltInDatabase: Bool {
        PluginMetadataRegistry.shared.snapshot(for: type)?
            .connection.hidesBuiltInDatabase ?? false
    }

    /// This is deliberately not `requiresAuthentication`: whether a driver needs credentials says
    /// nothing about whether it accepts a database name.
    var showsBuiltInDatabaseField: Bool {
        ConnectionDatabaseRequirement.showsBuiltInField(for: type)
    }

    var requiresDatabaseValue: Bool {
        ConnectionDatabaseRequirement.requiresValue(for: type)
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "Connection name is required"))
        }
        let mode = connectionMode
        if requiresDatabaseValue && database.trimmingCharacters(in: .whitespaces).isEmpty {
            let label = mode == .fileBased
                ? String(localized: "Database file path is required")
                : String(localized: "Database name is required")
            issues.append(label)
        }
        for field in connectionFields where field.isRequired && isFieldVisible(field) {
            let value = additionalFieldValues[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }
        issues += connectionFields.filter(isFieldVisible).compactMap { $0.rangeIssue(in: additionalFieldValues[$0.id] ?? "") }
        issues += endpointHostListIssues
        return issues
    }

    /// A pasted `https://` node is stored as host:port and SSL Mode picks the scheme, so Disabled
    /// would send the request, credentials included, over plain HTTP.
    private var endpointHostListIssues: [String] {
        guard let hostList = connectionFields.endpointHostList else { return [] }
        let entries = (additionalFieldValues[hostList.id] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var issues = entries
            .filter { HostListEndpoint.parse($0, defaultPort: type.defaultPort) == nil }
            .map { String(format: String(localized: "“%@” is not a host or host:port"), $0) }
        if let coordinator = coordinator?.value, coordinator.supportsSSL, coordinator.ssl.mode == .disabled,
           let secure = entries.first(where: HostListEndpoint.usesHTTPS) {
            issues.append(String(format: String(localized: "%@ needs an SSL Mode other than Disabled"), secure))
        }
        return issues
    }

    func setType(_ newType: DatabaseType) {
        guard newType != type else { return }
        type = newType
        coordinator?.value?.didChangeType(newType)
    }

    func setPort(_ newPort: String) {
        guard newPort != port else { return }
        port = newPort
        coordinator?.value?.didChangePort()
    }

    func applyTypeDefaults(forNewType newType: DatabaseType) {
        port = String(newType.defaultPort)
        if host.trimmingCharacters(in: .whitespaces).isEmpty, let defaultHost = newType.defaultHost {
            host = defaultHost
        }
        var values: [String: String] = [:]
        let fields = PluginManager.shared.additionalConnectionFields(for: newType)
        for field in fields where field.section == .connection {
            if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if let hostList = fields.endpointHostList, values[hostList.id] == nil {
            values[hostList.id] = HostListEndpoint.parse(host, defaultPort: newType.defaultPort)?.entry
        }
        additionalFieldValues = values
    }

    func applyNameSuggestionIfEmpty(_ suggestion: String) {
        guard name.isEmpty else { return }
        name = suggestion
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        PluginFieldRendering.isFieldVisible(field, type: type, values: resolvedFieldValues)
    }

    private var resolvedFieldValues: [String: String] {
        coordinator?.value?.allAdditionalFieldValues ?? additionalFieldValues
    }

    func load(from connection: DatabaseConnection) {
        name = connection.name
        host = connection.host
        port = connection.port > 0 ? String(connection.port) : ""
        database = connection.database
        type = connection.type
        sshForwardUnixSocketPath = connection.sshForwardUnixSocketPath ?? ""

        var values: [String: String] = [:]
        let allFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
        for field in allFields where field.section == .connection {
            if let value = connection.additionalFields[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if let hostList = allFields.endpointHostList {
            values[hostList.id] = Self.endpointList(values[hostList.id] ?? "", including: connection)
        }
        additionalFieldValues = values
    }

    /// Host and Port seed an empty list. A list saved before it stood in for Host and Port (Kafka's
    /// extra brokers) leaves Host out, so Host stays in, last, where the driver dials it. A Host
    /// equal to the form's own default was filled in while hidden, not typed, and stays out.
    static func endpointList(_ raw: String, including connection: DatabaseConnection) -> String? {
        let port = connection.port > 0 ? connection.port : connection.type.defaultPort
        let defaultHost = connection.type.defaultHost ?? "localhost"
        let hasRows = raw.split(separator: ",").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasRows else {
            return HostListEndpoint.parse(connection.host.isEmpty ? defaultHost : connection.host, defaultPort: port)?.entry
        }
        let listed = HostListEndpoint.parseList(raw, defaultPort: connection.type.defaultPort)
        guard connection.host != defaultHost || port != connection.type.defaultPort,
              let primary = HostListEndpoint.parse(connection.host, defaultPort: port),
              !listed.contains(primary)
        else { return raw }
        return raw + "," + primary.entry
    }

    func write(into fields: inout [String: String]) {
        for (key, value) in additionalFieldValues {
            fields[key] = value
        }
        let socketPath = sshForwardUnixSocketPath.trimmingCharacters(in: .whitespaces)
        if !socketPath.isEmpty {
            fields[DatabaseConnection.sshForwardUnixSocketPathKey] = socketPath
        }
    }
}

/// Advisory only. `ssh -L` needs the socket file itself, while libpq's own `host` convention
/// names the directory holding it, and mixing the two up is the usual mistake. Save is never
/// blocked on this: the SSH server is the only authority on whether the path resolves.
enum SSHForwardSocketPathIssue: Equatable {
    case notAbsolute
    case looksLikeDirectory
}

extension NetworkPaneViewModel {
    nonisolated static func socketPathIssue(for rawPath: String) -> SSHForwardSocketPathIssue? {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return .notAbsolute }
        guard !path.hasSuffix("/") else { return .looksLikeDirectory }
        return nil
    }

    var socketPathIssue: SSHForwardSocketPathIssue? {
        Self.socketPathIssue(for: sshForwardUnixSocketPath)
    }
}
