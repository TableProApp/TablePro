//
//  SyncRecordMapper.swift
//  TablePro
//
//  Maps between local models and CKRecord for CloudKit sync
//

import CloudKit
import Foundation
import os

/// CloudKit record types for sync
enum SyncRecordType: String, CaseIterable {
    case connection = "Connection"
    case group = "ConnectionGroup"
    case tag = "ConnectionTag"
    case settings = "AppSettings"
    case favorite = "SQLFavorite"
    case favoriteFolder = "SQLFavoriteFolder"
    case sshProfile = "SSHProfile"
}

/// Pure-function mapper between local models and CKRecord
struct SyncRecordMapper {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordMapper")
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Current schema version stamped on every record
    static let schemaVersion: Int64 = 1

    // MARK: - Record Name Helpers

    static func recordID(type: SyncRecordType, id: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        let recordName: String
        switch type {
        case .connection: recordName = "Connection_\(id)"
        case .group: recordName = "Group_\(id)"
        case .tag: recordName = "Tag_\(id)"
        case .settings: recordName = "Settings_\(id)"
        case .favorite: recordName = "Favorite_\(id)"
        case .favoriteFolder: recordName = "FavoriteFolder_\(id)"
        case .sshProfile: recordName = "SSHProfile_\(id)"
        }
        return CKRecord.ID(recordName: recordName, zoneID: zone)
    }

    // MARK: - Connection

    static func toCKRecord(_ connection: DatabaseConnection, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .connection, id: connection.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)

        record["connectionId"] = connection.id.uuidString as CKRecordValue
        record["name"] = connection.name as CKRecordValue
        record["host"] = connection.host as CKRecordValue
        record["port"] = Int64(connection.port) as CKRecordValue
        record["database"] = connection.database as CKRecordValue
        record["username"] = connection.username as CKRecordValue
        record["type"] = connection.type.rawValue as CKRecordValue
        record["color"] = connection.color.rawValue as CKRecordValue
        record["safeModeLevel"] = connection.safeModeLevel.rawValue as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue
        record["sortOrder"] = Int64(connection.sortOrder) as CKRecordValue

        if let tagId = connection.tagId {
            record["tagId"] = tagId.uuidString as CKRecordValue
        }
        if let groupId = connection.groupId {
            record["groupId"] = groupId.uuidString as CKRecordValue
        }
        if let aiPolicy = connection.aiPolicy {
            record["aiPolicy"] = aiPolicy.rawValue as CKRecordValue
        }
        if !connection.aiAlwaysAllowedTools.isEmpty {
            let sorted = Array(connection.aiAlwaysAllowedTools).sorted()
            record["aiAlwaysAllowedTools"] = sorted as CKRecordValue
        }
        if let redisDatabase = connection.redisDatabase {
            record["redisDatabase"] = Int64(redisDatabase) as CKRecordValue
        }
        if let startupCommands = connection.startupCommands {
            record["startupCommands"] = startupCommands as CKRecordValue
        }
        if let sshProfileId = connection.sshProfileId {
            record["sshProfileId"] = sshProfileId.uuidString as CKRecordValue
        }

        // Encode complex structs as JSON Data — contract device-local paths
        // to portable ~/… form so they resolve correctly on other devices.
        // Note: sshTunnelMode is intentionally NOT synced — it is re-derived
        // on decode from sshConfig + sshProfileId. If adding sshTunnelMode to
        // the sync schema in the future, apply path contraction to its snapshot.
        do {
            let sshData = try encoder.encode(Self.makePortable(connection.sshConfig))
            record["sshConfigJson"] = sshData as CKRecordValue
        } catch {
            logger.warning("Failed to encode SSH config for sync: \(error.localizedDescription)")
        }
        do {
            let sslData = try encoder.encode(Self.makePortable(connection.sslConfig))
            record["sslConfigJson"] = sslData as CKRecordValue
        } catch {
            logger.warning("Failed to encode SSL config for sync: \(error.localizedDescription)")
        }
        if !connection.additionalFields.isEmpty {
            do {
                let fieldsData = try encoder.encode(connection.additionalFields)
                record["additionalFieldsJson"] = fieldsData as CKRecordValue
            } catch {
                logger.warning("Failed to encode additional fields for sync: \(error.localizedDescription)")
            }
        }

        return record
    }

    static func toConnection(_ record: CKRecord) -> DatabaseConnection? {
        guard let connectionIdString = record["connectionId"] as? String,
              let connectionId = UUID(uuidString: connectionIdString),
              let name = record["name"] as? String,
              let typeRawValue = record["type"] as? String
        else {
            logger.warning("Failed to decode connection from CKRecord: missing required fields")
            return nil
        }

        let host = record["host"] as? String ?? "localhost"
        let port = (record["port"] as? Int64).map { Int($0) } ?? 0
        let database = record["database"] as? String ?? ""
        let username = record["username"] as? String ?? ""
        let colorRaw = record["color"] as? String ?? ConnectionColor.none.rawValue
        let safeModeLevelRaw = record["safeModeLevel"] as? String ?? SafeModeLevel.silent.rawValue
        let tagId = (record["tagId"] as? String).flatMap { UUID(uuidString: $0) }
        let groupId = (record["groupId"] as? String).flatMap { UUID(uuidString: $0) }
        let aiPolicyRaw = record["aiPolicy"] as? String
        let aiAlwaysAllowedToolsArray = record["aiAlwaysAllowedTools"] as? [String] ?? []
        let redisDatabase = (record["redisDatabase"] as? Int64).map { Int($0) }
        let startupCommands = record["startupCommands"] as? String
        let sortOrder = (record["sortOrder"] as? Int64).map { Int($0) } ?? 0
        let sshProfileId = (record["sshProfileId"] as? String).flatMap { UUID(uuidString: $0) }

        // Decode complex structs and expand portable ~/… paths to device-local form.
        var sshConfig = SSHConfiguration()
        if let sshData = record["sshConfigJson"] as? Data {
            sshConfig = (try? decoder.decode(SSHConfiguration.self, from: sshData)) ?? SSHConfiguration()
            Self.expandPaths(&sshConfig)
        }

        var sslConfig = SSLConfiguration()
        if let sslData = record["sslConfigJson"] as? Data {
            sslConfig = (try? decoder.decode(SSLConfiguration.self, from: sslData)) ?? SSLConfiguration()
            Self.expandPaths(&sslConfig)
        }

        var additionalFields: [String: String]?
        if let fieldsData = record["additionalFieldsJson"] as? Data {
            additionalFields = try? decoder.decode([String: String].self, from: fieldsData)
        }

        return DatabaseConnection(
            id: connectionId,
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: DatabaseType(rawValue: typeRawValue),
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: ConnectionColor(rawValue: colorRaw) ?? .none,
            tagId: tagId,
            groupId: groupId,
            sshProfileId: sshProfileId,
            safeModeLevel: SafeModeLevel(rawValue: safeModeLevelRaw) ?? .silent,
            aiPolicy: aiPolicyRaw.flatMap { AIConnectionPolicy(rawValue: $0) },
            aiAlwaysAllowedTools: Set(aiAlwaysAllowedToolsArray),
            redisDatabase: redisDatabase,
            startupCommands: startupCommands,
            sortOrder: sortOrder,
            additionalFields: additionalFields
        )
    }

    // MARK: - Connection Group

    static func toCKRecord(_ group: ConnectionGroup, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .group, id: group.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: recordID)

        record["groupId"] = group.id.uuidString as CKRecordValue
        record["name"] = group.name as CKRecordValue
        record["color"] = group.color.rawValue as CKRecordValue
        if let parentId = group.parentId {
            record["parentId"] = parentId.uuidString as CKRecordValue
        }
        record["sortOrder"] = Int64(group.sortOrder) as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    static func toGroup(_ record: CKRecord) -> ConnectionGroup? {
        guard let groupIdString = record["groupId"] as? String,
              let groupId = UUID(uuidString: groupIdString),
              let name = record["name"] as? String
        else {
            logger.warning("Failed to decode group from CKRecord: missing required fields")
            return nil
        }

        let colorRaw = record["color"] as? String ?? ConnectionColor.none.rawValue
        let parentId = (record["parentId"] as? String).flatMap { UUID(uuidString: $0) }
        let sortOrder = (record["sortOrder"] as? Int64).map { Int($0) } ?? 0

        return ConnectionGroup(
            id: groupId,
            name: name,
            color: ConnectionColor(rawValue: colorRaw) ?? .none,
            parentId: parentId,
            sortOrder: sortOrder
        )
    }

    // MARK: - Connection Tag

    static func toCKRecord(_ tag: ConnectionTag, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .tag, id: tag.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.tag.rawValue, recordID: recordID)

        record["tagId"] = tag.id.uuidString as CKRecordValue
        record["name"] = tag.name as CKRecordValue
        record["isPreset"] = Int64(tag.isPreset ? 1 : 0) as CKRecordValue
        record["color"] = tag.color.rawValue as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    static func toTag(_ record: CKRecord) -> ConnectionTag? {
        guard let tagIdString = record["tagId"] as? String,
              let tagId = UUID(uuidString: tagIdString),
              let name = record["name"] as? String
        else {
            logger.warning("Failed to decode tag from CKRecord: missing required fields")
            return nil
        }

        let isPreset = (record["isPreset"] as? Int64 ?? 0) != 0
        let colorRaw = record["color"] as? String ?? ConnectionColor.gray.rawValue

        return ConnectionTag(
            id: tagId,
            name: name,
            isPreset: isPreset,
            color: ConnectionColor(rawValue: colorRaw) ?? .gray
        )
    }

    // MARK: - App Settings

    static func toCKRecord(
        category: String,
        settingsData: Data,
        in zone: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = recordID(type: .settings, id: category, in: zone)
        let record = CKRecord(recordType: SyncRecordType.settings.rawValue, recordID: recordID)

        record["category"] = category as CKRecordValue
        record["settingsJson"] = settingsData as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        return record
    }

    static func settingsCategory(from record: CKRecord) -> String? {
        record["category"] as? String
    }

    static func settingsData(from record: CKRecord) -> Data? {
        record["settingsJson"] as? Data
    }

    // MARK: - SSH Profile

    static func toCKRecord(_ profile: SSHProfile, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = recordID(type: .sshProfile, id: profile.id.uuidString, in: zone)
        let record = CKRecord(recordType: SyncRecordType.sshProfile.rawValue, recordID: recordID)

        record["profileId"] = profile.id.uuidString as CKRecordValue
        record["name"] = profile.name as CKRecordValue
        record["host"] = profile.host as CKRecordValue
        if let port = profile.port {
            record["port"] = Int64(port) as CKRecordValue
        }
        record["username"] = profile.username as CKRecordValue
        record["authMethod"] = profile.authMethod.rawValue as CKRecordValue
        record["privateKeyPath"] = PathPortability.contractHome(profile.privateKeyPath) as CKRecordValue
        record["agentSocketPath"] = PathPortability.contractHome(profile.agentSocketPath) as CKRecordValue
        record["totpMode"] = profile.totpMode.rawValue as CKRecordValue
        record["totpAlgorithm"] = profile.totpAlgorithm.rawValue as CKRecordValue
        record["totpDigits"] = Int64(profile.totpDigits) as CKRecordValue
        record["totpPeriod"] = Int64(profile.totpPeriod) as CKRecordValue
        record["modifiedAtLocal"] = Date() as CKRecordValue
        record["schemaVersion"] = schemaVersion as CKRecordValue

        if !profile.jumpHosts.isEmpty {
            do {
                let portableJumpHosts = Self.makePortable(profile.jumpHosts)
                let jumpHostsData = try encoder.encode(portableJumpHosts)
                record["jumpHostsJson"] = jumpHostsData as CKRecordValue
            } catch {
                logger.warning("Failed to encode jump hosts for sync: \(error.localizedDescription)")
            }
        }

        return record
    }

    static func toSSHProfile(_ record: CKRecord) -> SSHProfile? {
        guard let profileIdString = record["profileId"] as? String,
              let profileId = UUID(uuidString: profileIdString),
              let name = record["name"] as? String
        else {
            logger.warning("Failed to decode SSH profile from CKRecord: missing required fields")
            return nil
        }

        let host = record["host"] as? String ?? ""
        let port = (record["port"] as? Int64).map { Int($0) }
        let username = record["username"] as? String ?? ""
        let authMethodRaw = record["authMethod"] as? String ?? SSHAuthMethod.password.rawValue
        let privateKeyPath = PathPortability.expandHome(record["privateKeyPath"] as? String ?? "")
        let agentSocketPath = PathPortability.expandHome(record["agentSocketPath"] as? String ?? "")
        let totpModeRaw = record["totpMode"] as? String ?? TOTPMode.none.rawValue
        let totpAlgorithmRaw = record["totpAlgorithm"] as? String ?? TOTPAlgorithm.sha1.rawValue
        let totpDigits = (record["totpDigits"] as? Int64).map { Int($0) } ?? 6
        let totpPeriod = (record["totpPeriod"] as? Int64).map { Int($0) } ?? 30

        var jumpHosts: [SSHJumpHost] = []
        if let jumpHostsData = record["jumpHostsJson"] as? Data {
            jumpHosts = (try? decoder.decode([SSHJumpHost].self, from: jumpHostsData)) ?? []
            Self.expandPaths(&jumpHosts)
        }

        return SSHProfile(
            id: profileId,
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: SSHAuthMethod(rawValue: authMethodRaw) ?? .password,
            privateKeyPath: privateKeyPath,
            agentSocketPath: agentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: TOTPMode(rawValue: totpModeRaw) ?? .none,
            totpAlgorithm: TOTPAlgorithm(rawValue: totpAlgorithmRaw) ?? .sha1,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )
    }

    // MARK: - Path Portability
    // Contract device-local paths to portable ~/… form before pushing to iCloud,
    // expand them back to device-local form when pulling. Matches the proven
    // pattern in ConnectionExportService.

    private static func makePortable(_ ssh: SSHConfiguration) -> SSHConfiguration {
        var config = ssh
        config.privateKeyPath = PathPortability.contractHome(config.privateKeyPath)
        config.agentSocketPath = PathPortability.contractHome(config.agentSocketPath)
        config.jumpHosts = makePortable(config.jumpHosts)
        return config
    }

    private static func expandPaths(_ ssh: inout SSHConfiguration) {
        ssh.privateKeyPath = PathPortability.expandHome(ssh.privateKeyPath)
        ssh.agentSocketPath = PathPortability.expandHome(ssh.agentSocketPath)
        expandPaths(&ssh.jumpHosts)
    }

    private static func makePortable(_ ssl: SSLConfiguration) -> SSLConfiguration {
        var config = ssl
        config.caCertificatePath = PathPortability.contractHome(config.caCertificatePath)
        config.clientCertificatePath = PathPortability.contractHome(config.clientCertificatePath)
        config.clientKeyPath = PathPortability.contractHome(config.clientKeyPath)
        return config
    }

    private static func expandPaths(_ ssl: inout SSLConfiguration) {
        ssl.caCertificatePath = PathPortability.expandHome(ssl.caCertificatePath)
        ssl.clientCertificatePath = PathPortability.expandHome(ssl.clientCertificatePath)
        ssl.clientKeyPath = PathPortability.expandHome(ssl.clientKeyPath)
    }

    private static func makePortable(_ jumpHosts: [SSHJumpHost]) -> [SSHJumpHost] {
        jumpHosts.map { host in
            var h = host
            h.privateKeyPath = PathPortability.contractHome(h.privateKeyPath)
            return h
        }
    }

    private static func expandPaths(_ jumpHosts: inout [SSHJumpHost]) {
        jumpHosts = jumpHosts.map { host in
            var h = host
            h.privateKeyPath = PathPortability.expandHome(h.privateKeyPath)
            return h
        }
    }
}
