//
//  SSHProfile.swift
//  TablePro
//

import Foundation

struct SSHProfile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: SSHAuthMethod
    var privateKeyPath: String
    var useSSHConfig: Bool
    var agentSocketPath: String
    var jumpHosts: [SSHJumpHost]
    var totpMode: TOTPMode
    var totpAlgorithm: TOTPAlgorithm
    var totpDigits: Int
    var totpPeriod: Int

    init(
        id: UUID = UUID(),
        name: String,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        privateKeyPath: String = "",
        useSSHConfig: Bool = true,
        agentSocketPath: String = "",
        jumpHosts: [SSHJumpHost] = [],
        totpMode: TOTPMode = .none,
        totpAlgorithm: TOTPAlgorithm = .sha1,
        totpDigits: Int = 6,
        totpPeriod: Int = 30
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.useSSHConfig = useSSHConfig
        self.agentSocketPath = agentSocketPath
        self.jumpHosts = jumpHosts
        self.totpMode = totpMode
        self.totpAlgorithm = totpAlgorithm
        self.totpDigits = totpDigits
        self.totpPeriod = totpPeriod
    }

    func toSSHConfiguration() -> SSHConfiguration {
        var config = SSHConfiguration()
        config.enabled = true
        config.host = host
        config.port = port
        config.username = username
        config.authMethod = authMethod
        config.privateKeyPath = privateKeyPath
        config.useSSHConfig = useSSHConfig
        config.agentSocketPath = agentSocketPath
        config.jumpHosts = jumpHosts
        config.totpMode = totpMode
        config.totpAlgorithm = totpAlgorithm
        config.totpDigits = totpDigits
        config.totpPeriod = totpPeriod
        return config
    }

    static func fromSSHConfiguration(_ config: SSHConfiguration, name: String) -> SSHProfile {
        SSHProfile(
            name: name,
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            privateKeyPath: config.privateKeyPath,
            useSSHConfig: config.useSSHConfig,
            agentSocketPath: config.agentSocketPath,
            jumpHosts: config.jumpHosts,
            totpMode: config.totpMode,
            totpAlgorithm: config.totpAlgorithm,
            totpDigits: config.totpDigits,
            totpPeriod: config.totpPeriod
        )
    }
}
