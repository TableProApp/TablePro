//
//  DataGripDataSourceParser.swift
//  TablePro
//

import Foundation

struct DataGripDataSource {
    let uuid: String
    let name: String
    let driverRef: String
    let jdbcURL: String
    var username: String
    let groupName: String?
    let ssh: DataGripSSHReference?
    let ssl: DataGripSSLProperties?
}

struct DataGripSSHReference {
    let enabled: Bool
    let configId: String?
    let inlineHost: String?
    let inlinePort: Int?
    let inlineUser: String?
}

struct DataGripSSLProperties {
    let mode: String?
    let caCertPath: String?
    let clientCertPath: String?
    let clientKeyPath: String?
}

struct DataGripSSHConfig {
    let id: String
    let host: String
    let port: Int?
    let username: String
    let authType: String
    let keyPath: String?
}

enum DataGripDataSourceParser {
    static func parseDataSources(_ data: Data) -> [DataGripDataSource] {
        guard let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//data-source") else { return [] }

        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            return parseDataSource(element)
        }
    }

    static func parseSSHConfigs(_ data: Data) -> [String: DataGripSSHConfig] {
        guard let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//sshConfig") else { return [:] }

        var result: [String: DataGripSSHConfig] = [:]
        for node in nodes {
            guard let element = node as? XMLElement,
                  let id = element.attr("id") else { continue }
            let config = DataGripSSHConfig(
                id: id,
                host: element.attr("host") ?? "",
                port: element.attr("port").flatMap { Int($0) },
                username: element.attr("username") ?? "",
                authType: element.attr("authType") ?? "PASSWORD",
                keyPath: element.attr("keyPath")
            )
            result[id] = config
        }
        return result
    }

    /// `dataSources.local.xml` holds the user name and per-user secrets metadata
    /// that the shared `dataSources.xml` omits. Returns user names keyed by data-source UUID.
    static func parseLocalUserNames(_ data: Data) -> [String: String] {
        guard let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//data-source") else { return [:] }

        var result: [String: String] = [:]
        for node in nodes {
            guard let element = node as? XMLElement,
                  let uuid = element.attr("uuid"),
                  let user = element.childText("user-name"), !user.isEmpty else { continue }
            result[uuid] = user
        }
        return result
    }

    // MARK: - Private

    private static func parseDataSource(_ element: XMLElement) -> DataGripDataSource? {
        guard let uuid = element.attr("uuid"),
              let driverRef = element.childText("driver-ref"),
              let jdbcURL = element.childText("jdbc-url"), !jdbcURL.isEmpty else { return nil }

        let name = element.attr("name") ?? uuid
        let username = element.childText("user-name") ?? ""
        let groupName = element.attr("group-name").flatMap { $0.isEmpty ? nil : $0 }

        return DataGripDataSource(
            uuid: uuid,
            name: name,
            driverRef: driverRef,
            jdbcURL: jdbcURL,
            username: username,
            groupName: groupName,
            ssh: parseSSHReference(element),
            ssl: parseSSLProperties(element)
        )
    }

    private static func parseSSHReference(_ element: XMLElement) -> DataGripSSHReference? {
        guard let ssh = element.elements(forName: "ssh-properties").first else { return nil }

        let enabled = (ssh.childText("enabled") ?? ssh.attr("enabled")) == "true"
        guard enabled else { return nil }

        let configId = ssh.childText("ssh-config-id") ?? ssh.attr("ssh-config-id")
        return DataGripSSHReference(
            enabled: true,
            configId: configId.flatMap { $0.isEmpty ? nil : $0 },
            inlineHost: ssh.attr("host"),
            inlinePort: ssh.attr("port").flatMap { Int($0) },
            inlineUser: ssh.attr("user") ?? ssh.attr("username")
        )
    }

    private static func parseSSLProperties(_ element: XMLElement) -> DataGripSSLProperties? {
        guard let ssl = element.elements(forName: "ssl-properties").first else { return nil }

        let enabled = (ssl.childText("enabled") ?? ssl.attr("enabled")) == "true"
        guard enabled else { return nil }

        return DataGripSSLProperties(
            mode: ssl.childText("ssl-mode") ?? ssl.childText("mode") ?? ssl.attr("ssl-mode"),
            caCertPath: ssl.childText("ca-file") ?? ssl.childText("ca-cert"),
            clientCertPath: ssl.childText("client-cert-file") ?? ssl.childText("client-cert"),
            clientKeyPath: ssl.childText("client-key-file") ?? ssl.childText("client-key")
        )
    }
}

private extension XMLElement {
    func childText(_ name: String) -> String? {
        elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}
