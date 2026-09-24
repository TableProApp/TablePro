import Foundation

struct XLSXRelationship: Equatable {
    let identifier: String
    let type: String
    let target: String

    func hasType(_ suffix: String) -> Bool {
        type.hasSuffix("/" + suffix)
    }
}

enum XLSXPackage {
    static let rootRelationshipsPath = "_rels/.rels"
    static let defaultWorkbookPath = "xl/workbook.xml"

    static func workbookPath(in archive: ZipArchive) -> String {
        let root = relationships(atPath: rootRelationshipsPath, in: archive)
        guard let document = root.first(where: { $0.hasType("officeDocument") }) else { return defaultWorkbookPath }
        return resolve(document.target, relativeTo: "", in: archive)
    }

    static func relationships(ofPart partPath: String, in archive: ZipArchive) -> [XLSXRelationship] {
        relationships(atPath: relationshipsPath(ofPart: partPath), in: archive)
    }

    static func relationshipsPath(ofPart partPath: String) -> String {
        var components = partPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fileName = components.removeLast()
        components.append("_rels")
        components.append(fileName + ".rels")
        return components.joined(separator: "/")
    }

    static func resolve(_ target: String, relativeTo partPath: String, in archive: ZipArchive) -> String {
        let resolved = resolvePath(target, relativeTo: partPath)
        guard archive.entry(matching: resolved) == nil,
              let decoded = resolved.removingPercentEncoding,
              archive.entry(matching: decoded) != nil else { return resolved }
        return decoded
    }

    static func resolvePath(_ target: String, relativeTo partPath: String) -> String {
        var components: [Substring] = []
        if !target.hasPrefix("/") {
            components = partPath.split(separator: "/", omittingEmptySubsequences: true)
            if !components.isEmpty { components.removeLast() }
        }
        for piece in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(piece)
            }
        }
        return components.joined(separator: "/")
    }

    private static func relationships(atPath path: String, in archive: ZipArchive) -> [XLSXRelationship] {
        guard let entry = archive.entry(matching: path), let data = try? archive.data(for: entry) else { return [] }
        return data.withUnsafeBytes { raw in
            parseRelationships(raw.bindMemory(to: UInt8.self))
        }
    }

    private static func parseRelationships(_ bytes: UnsafeBufferPointer<UInt8>) -> [XLSXRelationship] {
        var scanner = XMLByteScanner(bytes: bytes, isFinal: true)
        var result: [XLSXRelationship] = []
        while true {
            switch scanner.next() {
            case .startTag(let name, let attributes, _):
                guard scanner.isNamed(name, "Relationship"),
                      let identifier = scanner.attribute("Id", in: attributes),
                      let type = scanner.attribute("Type", in: attributes),
                      let target = scanner.attribute("Target", in: attributes) else { continue }
                if let mode = scanner.attribute("TargetMode", in: attributes), scanner.matches(mode, "External") {
                    continue
                }
                result.append(XLSXRelationship(
                    identifier: scanner.string(identifier),
                    type: scanner.string(type),
                    target: scanner.string(target)
                ))
            case .endTag, .text, .characterData, .markup:
                continue
            case .incomplete, .end:
                return result
            }
        }
    }
}

struct XLSXWorkbookPart {
    struct SheetEntry {
        let name: String
        let visibility: XLSXSheetVisibility
        let relationshipIdentifier: String?
    }

    var sheets: [SheetEntry] = []
    var usesDate1904 = false

    static func parse(_ data: Data) -> XLSXWorkbookPart {
        data.withUnsafeBytes { raw in
            parse(raw.bindMemory(to: UInt8.self))
        }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> XLSXWorkbookPart {
        var scanner = XMLByteScanner(bytes: bytes, isFinal: true)
        var part = XLSXWorkbookPart()
        while true {
            switch scanner.next() {
            case .startTag(let name, let attributes, _):
                if scanner.isNamed(name, "workbookPr") {
                    part.usesDate1904 = scanner.attribute("date1904", in: attributes).map {
                        scanner.matches($0, "1") || scanner.matches($0, "true")
                    } ?? false
                } else if scanner.isNamed(name, "sheet") {
                    part.sheets.append(SheetEntry(
                        name: scanner.attribute("name", in: attributes).map(scanner.string) ?? "",
                        visibility: visibility(scanner, scanner.attribute("state", in: attributes)),
                        relationshipIdentifier: scanner.prefixedAttribute("id", in: attributes).map(scanner.string)
                    ))
                }
            case .endTag, .text, .characterData, .markup:
                continue
            case .incomplete, .end:
                return part
            }
        }
    }

    private static func visibility(_ scanner: XMLByteScanner, _ state: Range<Int>?) -> XLSXSheetVisibility {
        guard let state else { return .visible }
        if scanner.matches(state, "hidden") { return .hidden }
        if scanner.matches(state, "veryHidden") { return .veryHidden }
        return .visible
    }
}
