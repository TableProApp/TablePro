//
//  ConnectionDraft+URLImport.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProRedisCore
import TableProSSHConfig

enum URLApplyPolicy: Equatable, Sendable {
    // Import from URL and a paste into a connection that is not saved yet: the whole mapping.
    case newConnection
    // A paste into a saved connection: never lowers Safe Mode, weakens TLS, renames or adds raw driver options.
    case existingConnection
}

extension ConnectionDraft {
    // Never a tunnel command, startup SQL or script: a URL carries none, and app-managed keys are dropped.
    mutating func apply(
        _ parsed: ParsedConnectionURL,
        traits: ConnectionTypeTraits,
        policy: URLApplyPolicy,
        safeModeFloor: SafeModeFloor? = nil
    ) {
        let isNew = policy == .newConnection
        applyEndpoint(parsed, traits: traits, isNew: isNew)
        applySSL(parsed, isNew: isNew)
        applySSH(parsed)

        if let hostList = traits.fields.endpointHostList {
            if let multiHost = parsed.multiHost, !multiHost.isEmpty {
                fieldValues[hostList.id] = multiHost
            } else {
                fieldValues[hostList.id] = HostListEndpoint.parse(parsed.host, defaultPort: parsed.resolvedPort)?.entry
            }
        }

        applyDriverOptions(parsed, traits: traits, isNew: isNew)

        if let hex = parsed.statusColor, !hex.isEmpty {
            appearance.color = ConnectionURLParser.connectionColor(fromHex: hex)
        }
        if let environment = parsed.environment {
            setEnvironment(environment)
        }
        applyEngineFields(parsed, traits: traits)

        if isNew {
            if let connectionName = parsed.connectionName, !connectionName.isEmpty {
                name = connectionName
            } else if name.isEmpty {
                name = parsed.suggestedName
            }
        }
        applySafeMode(parsed, isNew: isNew, floor: safeModeFloor)
    }

    private mutating func applyEndpoint(_ parsed: ParsedConnectionURL, traits: ConnectionTypeTraits, isNew: Bool) {
        if let socketPath = parsed.localSocketPath, traits.supportsLocalSocket {
            endpoint = .localSocket
            localSocketPath = socketPath
            selectTransport(nil)
        } else {
            // Left on Socket, normalizing would drop the SSH server the URL names.
            endpoint = .hostAndPort
        }
        host = parsed.host
        portText = String(parsed.resolvedPort)
        if isNew || !parsed.database.isEmpty {
            database = parsed.database
        }
        if isNew || !parsed.username.isEmpty {
            credentials.username = parsed.username
        }
        if isNew || !parsed.password.isEmpty {
            credentials.password = parsed.password
        }
    }

    private mutating func applySSL(_ parsed: ParsedConnectionURL, isNew: Bool) {
        let resolution = parsed.sslModeResolution
        guard isNew || Self.strictness(of: resolution.mode) >= Self.strictness(of: ssl.mode) else { return }
        applyImportedSSL(resolution)
    }

    static func strictness(of mode: SSLMode) -> Int {
        switch mode {
        case .disabled: return 0
        case .preferred: return 1
        case .required: return 2
        case .verifyCa: return 3
        case .verifyIdentity: return 4
        }
    }

    private mutating func applySSH(_ parsed: ParsedConnectionURL) {
        guard let sshHost = parsed.sshHost else { return }
        selectTransport(.ssh)
        ssh.profileId = nil
        ssh.host = sshHost
        ssh.port = parsed.sshPort.map(String.init) ?? ""
        ssh.username = parsed.sshUsername ?? ""
        if let sshPassword = parsed.sshPassword, !sshPassword.isEmpty {
            ssh.password = sshPassword
        }
        if parsed.usePrivateKey == true {
            ssh.authMethod = .privateKey
        }
        if parsed.useSSHAgent == true {
            ssh.authMethod = .sshAgent
            ssh.applyAgentSocketPath(parsed.agentSocket ?? "")
        }
        if parsed.sshNoAuth == true {
            ssh.authMethod = .none
        }
    }

    // Raw driver options reach the driver as typed, so a paste into a saved connection adds none of them.
    private mutating func applyDriverOptions(_ parsed: ParsedConnectionURL, traits: ConnectionTypeTraits, isNew: Bool) {
        if isNew {
            let replaced = fieldValues.keys.filter {
                ($0.hasPrefix("mongo") || $0.hasPrefix(ConnectionSecretOptions.mongoOptionPrefix)) && $0 != "mongoHosts"
            }
            for key in replaced {
                fieldValues.removeValue(forKey: key)
            }
        }
        if let authSource = parsed.authSource, !authSource.isEmpty {
            fieldValues["mongoAuthSource"] = authSource
        }
        if parsed.useSrv {
            fieldValues["mongoUseSrv"] = "true"
        }
        for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
            switch key.lowercased() {
            case "authmechanism":
                fieldValues["mongoAuthMechanism"] = value
            case "replicaset":
                fieldValues["mongoReplicaSet"] = value
            case "uuidrepresentation":
                fieldValues["mongoUuidRepresentation"] = value
            // Secrets go to the Keychain through SSL and a secure field, never into a plain option.
            case "tlscertificatekeyfile", "sslclientcertificatekeyfile":
                ssl.clientCertPath = value
                ssl.clientKeyPath = value
            case "tlscertificatekeyfilepassword", "sslclientcertificatekeypassword":
                ssl.clientKeyPassphrase = value
            case "authmechanismproperties":
                let split = ConnectionSecretOptions.splitSessionToken(from: value)
                if isNew, let remaining = split.remaining {
                    fieldValues["\(ConnectionSecretOptions.mongoOptionPrefix)\(key)"] = remaining
                }
                if let token = split.sessionToken {
                    fieldValues[ConnectionSecretOptions.mongoSessionTokenFieldId] = token
                }
            case "proxypassword":
                // libmongoc has no proxy options, so the password would only sit in the record.
                continue
            default:
                if isNew {
                    fieldValues["\(ConnectionSecretOptions.mongoOptionPrefix)\(key)"] = value
                }
            }
        }
        if traits.field(RedisDatabaseIndex.fieldName) != nil, let redisDatabase = parsed.redisDatabase {
            fieldValues[RedisDatabaseIndex.fieldName] = String(redisDatabase)
        }
        if let serviceName = parsed.oracleServiceName, !serviceName.isEmpty {
            fieldValues["oracleServiceName"] = serviceName
        }
        let refused = ConnectionFormEdits.appManagedAdditionalFieldIDs
        for (fieldId, value) in parsed.additionalFields where !refused.contains(fieldId) {
            fieldValues[fieldId] = value
        }
    }

    private mutating func applyEngineFields(_ parsed: ParsedConnectionURL, traits: ConnectionTypeTraits) {
        switch traits.pluginTypeId {
        case "libSQL" where !parsed.host.isEmpty:
            var urlString = "https://\(HostListEndpoint.urlHost(parsed.host))"
            if let port = parsed.port {
                urlString += ":\(port)"
            }
            fieldValues["databaseUrl"] = urlString
        case "Cloudflare D1" where !parsed.host.isEmpty:
            fieldValues["cfAccountId"] = parsed.host
        case "DuckDB":
            if parsed.host.isEmpty {
                fieldValues["duckdbMode"] = "local"
                fieldValues["duckdbFilePath"] = parsed.database
            } else {
                fieldValues["duckdbMode"] = "remote"
                fieldValues["duckdbHost"] = parsed.host
                if let port = parsed.port {
                    fieldValues["duckdbPort"] = String(port)
                }
                if !parsed.database.isEmpty {
                    fieldValues["duckdbAlias"] = parsed.database
                }
            }
        default:
            break
        }
    }

    private mutating func applySafeMode(_ parsed: ParsedConnectionURL, isNew: Bool, floor: SafeModeFloor?) {
        guard let raw = parsed.safeModeLevel, let level = SafeModeLevel.from(urlInteger: raw) else { return }
        if isNew {
            safety.safeModeLevel = level
            safety.userSetSafeMode = true
            return
        }
        let current = floor?.raising(safety.safeModeLevel) ?? safety.safeModeLevel
        guard level.strictness > current.strictness else { return }
        safety.safeModeLevel = level
        safety.userSetSafeMode = true
    }

    static func changedValues(from old: ConnectionDraft, to new: ConnectionDraft, traits: ConnectionTypeTraits) -> [String] {
        var changes: [String] = []
        func note(_ label: String, _ changed: Bool) {
            if changed, !changes.contains(label) { changes.append(label) }
        }
        note(String(localized: "Type"), old.type != new.type)
        note(String(localized: "Name"), old.name != new.name)
        note(String(localized: "Host"), old.host != new.host)
        note(String(localized: "Port"), old.portText != new.portText)
        note(String(localized: "Socket"), old.endpoint != new.endpoint || old.localSocketPath != new.localSocketPath)
        note(String(localized: "Database"), old.database != new.database)
        note(String(localized: "Username"), old.credentials.username != new.credentials.username)
        note(String(localized: "Password"), old.credentials.password != new.credentials.password)
        note(String(localized: "SSL Mode"), old.ssl.mode != new.ssl.mode)
        note(
            String(localized: "Client Certificates"),
            old.ssl.clientCertPath != new.ssl.clientCertPath || old.ssl.clientKeyPath != new.ssl.clientKeyPath
                || old.ssl.clientKeyPassphrase != new.ssl.clientKeyPassphrase
        )
        if old.transport != new.transport {
            note(new.transport?.displayName ?? ConnectionTunnelKind.directDisplayName, true)
        }
        note(String(localized: "SSH Tunnel"), old.ssh != new.ssh && new.usesSSHServer)
        note(String(localized: "Environment"), old.environment != new.environment)
        note(String(localized: "Color"), old.appearance.color != new.appearance.color)
        note(String(localized: "Safe Mode"), old.safety.safeModeLevel != new.safety.safeModeLevel)
        let keys = Set(old.fieldValues.keys).union(new.fieldValues.keys)
        for key in keys.sorted() where old.fieldValues[key] != new.fieldValues[key] {
            note(traits.field(key)?.label ?? key, true)
        }
        return changes
    }
}
