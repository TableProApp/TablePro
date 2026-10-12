import Foundation

public enum XLSXSheetVisibility: String, Sendable, Equatable {
    case visible
    case hidden
    case veryHidden
}

public struct XLSXSheet: Sendable, Hashable, Identifiable {
    public let index: Int
    public let name: String
    public let visibility: XLSXSheetVisibility
    public let partPath: String

    public init(index: Int, name: String, visibility: XLSXSheetVisibility, partPath: String) {
        self.index = index
        self.name = name
        self.visibility = visibility
        self.partPath = partPath
    }

    public var id: String { partPath }

    public var isHidden: Bool { visibility != .visible }
}

public struct XLSXWorkbook: Sendable {
    public let archive: ZipArchive
    public let sheets: [XLSXSheet]
    public let dateSystem: XLSXDateSystem
    public let sharedStrings: XLSXSharedStrings
    public let styles: XLSXStyleSheet

    public init(
        archive: ZipArchive,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        try self.init(
            archive: archive,
            chunkSize: XLSXStreamingParse.defaultChunkSize,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    init(
        archive: ZipArchive,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool
    ) throws {
        let workbookPath = XLSXPackage.workbookPath(in: archive)
        guard let workbookEntry = archive.entry(matching: workbookPath) else {
            throw ZipArchive.Failure.entryNotFound(workbookPath)
        }
        let part = XLSXWorkbookPart.parse(try archive.data(for: workbookEntry))
        let relationships = XLSXPackage.relationships(ofPart: workbookEntry.path, in: archive)
        self.archive = archive
        self.sheets = Self.resolveSheets(part.sheets, relationships: relationships, workbookPath: workbookEntry.path, in: archive)
        self.dateSystem = part.usesDate1904 ? .base1904 : .base1900
        self.styles = Self.readStyles(relationships: relationships, workbookPath: workbookEntry.path, in: archive)
        self.sharedStrings = try Self.readSharedStrings(
            relationships: relationships,
            workbookPath: workbookEntry.path,
            in: archive,
            chunkSize: chunkSize,
            progress: progress,
            isCancelled: isCancelled
        )
        progress?(1)
    }

    public init(
        contentsOf url: URL,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        try self.init(archive: ZipArchive(contentsOf: url), progress: progress, isCancelled: isCancelled)
    }

    public var visibleSheets: [XLSXSheet] {
        sheets.filter { !$0.isHidden }
    }

    public func source(
        for sheet: XLSXSheet,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> XLSXSheetSource {
        try source(for: sheet, chunkSize: XLSXStreamingParse.defaultChunkSize, progress: progress, isCancelled: isCancelled)
    }

    func source(
        for sheet: XLSXSheet,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> XLSXSheetSource {
        try XLSXSheetReader.read(self, sheet: sheet, chunkSize: chunkSize, progress: progress, isCancelled: isCancelled)
    }

    private static func resolveSheets(
        _ entries: [XLSXWorkbookPart.SheetEntry],
        relationships: [XLSXRelationship],
        workbookPath: String,
        in archive: ZipArchive
    ) -> [XLSXSheet] {
        var byIdentifier: [String: XLSXRelationship] = [:]
        for relationship in relationships {
            byIdentifier[relationship.identifier] = relationship
        }
        var sheets: [XLSXSheet] = []
        for (position, entry) in entries.enumerated() {
            guard let path = partPath(of: entry, position: position, relationships: byIdentifier, workbookPath: workbookPath, in: archive) else {
                continue
            }
            sheets.append(XLSXSheet(index: sheets.count, name: entry.name, visibility: entry.visibility, partPath: path))
        }
        return sheets
    }

    private static func partPath(
        of entry: XLSXWorkbookPart.SheetEntry,
        position: Int,
        relationships: [String: XLSXRelationship],
        workbookPath: String,
        in archive: ZipArchive
    ) -> String? {
        guard !relationships.isEmpty else {
            let guessed = XLSXPackage.resolvePath("worksheets/sheet\(position + 1).xml", relativeTo: workbookPath)
            return archive.entry(matching: guessed)?.path
        }
        guard let identifier = entry.relationshipIdentifier,
              let relationship = relationships[identifier],
              relationship.hasType("worksheet") else { return nil }
        let resolved = XLSXPackage.resolve(relationship.target, relativeTo: workbookPath, in: archive)
        return archive.entry(matching: resolved)?.path ?? resolved
    }

    private static func partEntry(
        ofType type: String,
        fallback: String,
        relationships: [XLSXRelationship],
        workbookPath: String,
        in archive: ZipArchive
    ) -> ZipArchive.Entry? {
        if let relationship = relationships.first(where: { $0.hasType(type) }) {
            let resolved = XLSXPackage.resolve(relationship.target, relativeTo: workbookPath, in: archive)
            if let entry = archive.entry(matching: resolved) { return entry }
        }
        return archive.entry(matching: XLSXPackage.resolvePath(fallback, relativeTo: workbookPath))
    }

    private static func readStyles(
        relationships: [XLSXRelationship],
        workbookPath: String,
        in archive: ZipArchive
    ) -> XLSXStyleSheet {
        guard let entry = partEntry(
            ofType: "styles",
            fallback: "styles.xml",
            relationships: relationships,
            workbookPath: workbookPath,
            in: archive
        ), let data = try? archive.data(for: entry) else { return .empty }
        return XLSXStyleSheet.parse(data)
    }

    private static func readSharedStrings(
        relationships: [XLSXRelationship],
        workbookPath: String,
        in archive: ZipArchive,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> XLSXSharedStrings {
        guard let entry = partEntry(
            ofType: "sharedStrings",
            fallback: "sharedStrings.xml",
            relationships: relationships,
            workbookPath: workbookPath,
            in: archive
        ) else { return .empty }
        return try XLSXSharedStringsReader.read(
            archive,
            entry: entry,
            chunkSize: chunkSize,
            progress: progress,
            isCancelled: isCancelled
        )
    }
}
