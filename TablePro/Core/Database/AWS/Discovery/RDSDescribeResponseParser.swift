import Foundation

struct RDSDescribePage<Item: Sendable>: Sendable {
    let items: [Item]
    let marker: String?
}

enum RDSDescribeResponseParser {
    static func parseInstances(_ data: Data) -> RDSDescribePage<RDSInstance>? {
        guard let raw = RDSXMLRecordReader.read(data, itemElement: "DBInstance", memberElement: nil) else {
            return nil
        }
        return RDSDescribePage(items: raw.records.compactMap(instance(from:)), marker: raw.marker)
    }

    static func parseClusters(_ data: Data) -> RDSDescribePage<RDSCluster>? {
        guard let raw = RDSXMLRecordReader.read(
            data,
            itemElement: "DBCluster",
            memberElement: "DBClusterMember"
        ) else {
            return nil
        }
        return RDSDescribePage(items: raw.records.compactMap(cluster(from:)), marker: raw.marker)
    }

    private static func instance(from record: RDSXMLRecord) -> RDSInstance? {
        guard let identifier = record.text("DBInstanceIdentifier"), let engine = record.text("Engine") else {
            return nil
        }
        let address = record.text("Endpoint.Address")
        let port = record.integer("Endpoint.Port")
        return RDSInstance(
            identifier: identifier,
            engine: engine,
            engineVersion: record.text("EngineVersion"),
            status: record.text("DBInstanceStatus"),
            endpoint: address == nil && port == nil ? nil : RDSInstanceEndpoint(address: address, port: port),
            databaseName: record.text("DBName"),
            adminUsername: record.text("MasterUsername"),
            clusterIdentifier: record.text("DBClusterIdentifier"),
            iamAuthenticationEnabled: record.boolean("IAMDatabaseAuthenticationEnabled") ?? false,
            isPubliclyAccessible: record.boolean("PubliclyAccessible") ?? false
        )
    }

    private static func cluster(from record: RDSXMLRecord) -> RDSCluster? {
        guard let identifier = record.text("DBClusterIdentifier"), let engine = record.text("Engine") else {
            return nil
        }
        let members = record.members.compactMap { member -> RDSClusterMember? in
            guard let instanceIdentifier = member["DBInstanceIdentifier"] else { return nil }
            return RDSClusterMember(
                instanceIdentifier: instanceIdentifier,
                isWriter: member["IsClusterWriter"].map { $0.lowercased() == "true" } ?? false
            )
        }
        return RDSCluster(
            identifier: identifier,
            engine: engine,
            engineVersion: record.text("EngineVersion"),
            status: record.text("Status"),
            endpoint: record.text("Endpoint"),
            readerEndpoint: record.text("ReaderEndpoint"),
            port: record.integer("Port"),
            databaseName: record.text("DatabaseName"),
            adminUsername: record.text("MasterUsername"),
            iamAuthenticationEnabled: record.boolean("IAMDatabaseAuthenticationEnabled") ?? false,
            members: members
        )
    }
}

struct RDSXMLRecord: Sendable {
    var fields: [String: String] = [:]
    var members: [[String: String]] = []

    func text(_ key: String) -> String? {
        guard let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func integer(_ key: String) -> Int? {
        text(key).flatMap(Int.init)
    }

    func boolean(_ key: String) -> Bool? {
        text(key).map { $0.lowercased() == "true" }
    }
}

enum RDSXMLRecordReader {
    static func read(
        _ data: Data,
        itemElement: String,
        memberElement: String?
    ) -> (records: [RDSXMLRecord], marker: String?)? {
        let delegate = RDSXMLRecordDelegate(itemElement: itemElement, memberElement: memberElement)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return (delegate.records, delegate.marker)
    }
}

private final class RDSXMLRecordDelegate: NSObject, XMLParserDelegate {
    private(set) var records: [RDSXMLRecord] = []
    private(set) var marker: String?

    private let itemElement: String
    private let memberElement: String?

    private var itemPath: [String] = []
    private var memberPath: [String] = []
    private var current: RDSXMLRecord?
    private var currentMember: [String: String]?
    private var insideItem = false
    private var insideMember = false
    private var buffer = ""

    init(itemElement: String, memberElement: String?) {
        self.itemElement = itemElement
        self.memberElement = memberElement
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        buffer = ""
        if !insideItem, elementName == itemElement {
            insideItem = true
            itemPath = []
            current = RDSXMLRecord()
            return
        }
        guard insideItem else { return }
        if let memberElement, !insideMember, elementName == memberElement {
            insideMember = true
            memberPath = []
            currentMember = [:]
            return
        }
        if insideMember {
            memberPath.append(elementName)
        } else {
            itemPath.append(elementName)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""

        if !insideItem {
            if elementName == "Marker", !value.isEmpty {
                marker = value
            }
            return
        }

        if insideMember {
            if elementName == memberElement, memberPath.isEmpty {
                if let currentMember, !currentMember.isEmpty {
                    current?.members.append(currentMember)
                }
                self.currentMember = nil
                insideMember = false
                return
            }
            if !memberPath.isEmpty {
                let key = memberPath.joined(separator: ".")
                memberPath.removeLast()
                if !value.isEmpty {
                    currentMember?[key] = value
                }
            }
            return
        }

        if elementName == itemElement, itemPath.isEmpty {
            if let current {
                records.append(current)
            }
            current = nil
            insideItem = false
            return
        }

        guard !itemPath.isEmpty else { return }
        let key = itemPath.joined(separator: ".")
        itemPath.removeLast()
        if !value.isEmpty {
            current?.fields[key] = value
        }
    }
}
