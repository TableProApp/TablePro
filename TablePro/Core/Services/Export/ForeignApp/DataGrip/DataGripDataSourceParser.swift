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
    let username: String
    let groupName: String?
    let ssh: DataGripSSHReference?
    let ssl: DataGripSSLProperties?
}

/// A single `<data-source>` element. DataGrip splits one logical data source
/// across the shared `dataSources.xml` (driver, jdbc-url, group) and the
/// machine-local `dataSources.local.xml` (user name, ssh-properties,
/// ssl-properties). Fragments from both files merge by uuid before resolving.
struct DataGripDataSourceFragment {
    let uuid: String
    var name: String?
    var driverRef: String?
    var jdbcURL: String?
    var username: String?
    var groupName: String?
    var ssh: DataGripSSHReference?
    var ssl: DataGripSSLProperties?

    mutating func merge(_ other: DataGripDataSourceFragment) {
        name = other.name ?? name
        driverRef = other.driverRef ?? driverRef
        jdbcURL = other.jdbcURL ?? jdbcURL
        username = other.username ?? username
        groupName = other.groupName ?? groupName
        ssh = other.ssh ?? ssh
        ssl = other.ssl ?? ssl
    }

    func resolved() -> DataGripDataSource? {
        guard let driverRef, !driverRef.isEmpty,
              let jdbcURL, !jdbcURL.isEmpty else { return nil }
        return DataGripDataSource(
            uuid: uuid,
            name: name ?? uuid,
            driverRef: driverRef,
            jdbcURL: jdbcURL,
            username: username ?? "",
            groupName: groupName,
            ssh: ssh,
            ssl: ssl
        )
    }
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
    let authType: String?
    let keyPath: String?
}

enum DataGripDataSourceParser {
    static func parseFragments(_ data: Data) -> [DataGripDataSourceFragment] {
        guard let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//data-source") else { return [] }

        return nodes.compactMap { node in
            guard let element = node as? XMLElement, let uuid = element.attr("uuid") else { return nil }
            return parseFragment(element, uuid: uuid)
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
                authType: element.attr("authType"),
                keyPath: element.attr("keyPath").map { JetBrainsPathMacros.expand($0) }
            )
            result[id] = config
        }
        return result
    }

    // MARK: - Private

    private static func parseFragment(_ element: XMLElement, uuid: String) -> DataGripDataSourceFragment {
        var fragment = DataGripDataSourceFragment(uuid: uuid)
        fragment.name = element.attr("name").flatMap { $0.isEmpty ? nil : $0 }
        fragment.driverRef = element.childText("driver-ref")
        fragment.jdbcURL = element.childText("jdbc-url").flatMap { $0.isEmpty ? nil : $0 }
        fragment.username = element.childText("user-name").flatMap { $0.isEmpty ? nil : $0 }
        fragment.groupName = element.attr("group-name").flatMap { $0.isEmpty ? nil : $0 }
        fragment.ssh = parseSSHReference(element)
        fragment.ssl = parseSSLProperties(element)
        return fragment
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
        guard let ssl = element.elements(forName: "ssl-config").first,
              ssl.childText("enabled") == "true" else { return nil }

        return DataGripSSLProperties(
            mode: ssl.childText("mode"),
            caCertPath: ssl.certPath("ca-cert"),
            clientCertPath: ssl.certPath("client-cert"),
            clientKeyPath: ssl.certPath("client-key")
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

    func certPath(_ name: String) -> String? {
        childText(name).flatMap { $0.isEmpty ? nil : JetBrainsPathMacros.expand($0) }
    }
}
