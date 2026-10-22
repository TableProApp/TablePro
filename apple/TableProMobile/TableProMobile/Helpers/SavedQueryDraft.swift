import Foundation
import TableProImport
import TableProModels

nonisolated enum SavedQueryKeywordCheck: Equatable, Sendable {
    case valid
    case containsSpaces
    case inUse
    case shadowsSQLKeyword(String)

    var blocksSave: Bool {
        switch self {
        case .containsSpaces, .inUse:
            true
        case .valid, .shadowsSQLKeyword:
            false
        }
    }

    var message: String? {
        switch self {
        case .valid:
            nil
        case .containsSpaces:
            String(localized: "Keyword cannot contain spaces")
        case .inUse:
            String(localized: "This keyword is already in use")
        case .shadowsSQLKeyword(let keyword):
            String(format: String(localized: "Shadows the SQL keyword '%@'"), keyword.uppercased())
        }
    }
}

nonisolated struct SavedQueryValidation: Equatable, Sendable {
    let keywordCheck: SavedQueryKeywordCheck
    let exceedsSizeLimit: Bool
}

nonisolated struct SavedQueryDraft: Equatable, Sendable {
    var name: String
    var keyword: String
    var folderId: UUID?
    var isGlobal: Bool

    init(name: String, keyword: String = "", folderId: UUID? = nil, isGlobal: Bool = false) {
        self.name = name
        self.keyword = keyword
        self.folderId = folderId
        self.isGlobal = isGlobal
    }

    init(query: SavedQuery) {
        self.init(
            name: query.name,
            keyword: query.keyword ?? "",
            folderId: query.folderId,
            isGlobal: query.connectionId == nil
        )
    }

    init(saving sql: String) {
        self.init(name: SavedQueryName.derived(from: sql))
    }

    static func savableSQL(from editorText: String) -> String? {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Opened text leaves the caret at its end, where Run finds no statement past a trailing newline.
    static func editorText(opening sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var sizeLimitMessage: String {
        String(
            format: String(localized: "Saved queries are limited to %@ so they fit in iCloud."),
            ByteCountFormatter.string(fromByteCount: Int64(SavedQuerySize.maximumSyncableByteCount), countStyle: .file)
        )
    }

    static func hidesFolders(_ folders: [SavedQueryFolder], forScope scope: UUID?) -> Bool {
        folders.contains { !SavedQueryScopeRule.folder($0.connectionId, canHold: scope) }
    }

    static func acceptedName(_ proposed: String, replacing current: String?) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }

    static func renamedName(_ proposed: String, of query: SavedQuery) -> String? {
        guard let name = acceptedName(proposed, replacing: query.name),
              SavedQuerySize.byteCount(name: name, sql: query.query, keyword: query.keyword)
                <= SavedQuerySize.maximumSyncableByteCount
        else { return nil }
        return name
    }

    // A move never puts a query in a folder narrower than its own scope, or other connections lose it.
    static func move(_ query: inout SavedQuery, to folder: SavedQueryFolder?) {
        if let folder, !SavedQueryScopeRule.folder(folder.connectionId, canHold: query.connectionId) { return }
        query.folderId = folder?.id
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var normalizedKeyword: String? {
        SavedQueryKeyword.normalized(keyword)
    }

    func scope(in connectionId: UUID) -> UUID? {
        isGlobal ? nil : connectionId
    }

    func keywordCheck(isAvailable: Bool) -> SavedQueryKeywordCheck {
        Self.keywordCheck(normalizedKeyword, isAvailable: isAvailable)
    }

    private static func keywordCheck(_ keyword: String?, isAvailable: Bool) -> SavedQueryKeywordCheck {
        guard let keyword else { return .valid }
        guard SavedQueryKeyword.isValid(keyword) else { return .containsSpaces }
        guard isAvailable else { return .inUse }
        guard !SavedQueryKeyword.shadowsSQLKeyword(keyword) else { return .shadowsSQLKeyword(keyword) }
        return .valid
    }

    // Checks the row as it will be saved: an edit lands on the stored row, which a pull may have changed meanwhile.
    func validation(
        sql: String,
        savingOver live: SavedQuery?,
        changedSince opening: SavedQueryDraft,
        connectionId: UUID,
        folders: [SavedQueryFolder],
        isAvailable: (_ keyword: String, _ scope: UUID?) -> Bool
    ) -> SavedQueryValidation {
        var saved = live ?? newQuery(sql: sql, connectionId: connectionId)
        if live != nil {
            apply(to: &saved, changedSince: opening, connectionId: connectionId, folders: folders)
        }
        let keyword = saved.keyword
        return SavedQueryValidation(
            keywordCheck: Self.keywordCheck(keyword, isAvailable: keyword.map { isAvailable($0, saved.connectionId) } ?? true),
            exceedsSizeLimit: SavedQuerySize.byteCount(name: saved.name, sql: saved.query, keyword: keyword)
                > SavedQuerySize.maximumSyncableByteCount
        )
    }

    func canSave(sql: String, validation: SavedQueryValidation) -> Bool {
        !trimmedName.isEmpty
            && sql.contains { !$0.isWhitespace }
            && !validation.exceedsSizeLimit
            && !validation.keywordCheck.blocksSave
    }

    func resolvingFolder(among folders: [SavedQueryFolder], connectionId: UUID) -> SavedQueryDraft {
        guard let folderId,
              let folder = folders.first(where: { $0.id == folderId }),
              !SavedQueryScopeRule.folder(folder.connectionId, canHold: scope(in: connectionId))
        else { return self }
        var resolved = self
        resolved.folderId = nil
        return resolved
    }

    func newQuery(sql: String, connectionId: UUID, now: Date = Date()) -> SavedQuery {
        SavedQuery(
            name: trimmedName,
            query: sql,
            keyword: normalizedKeyword,
            folderId: folderId,
            connectionId: scope(in: connectionId),
            createdAt: now,
            updatedAt: now
        )
    }

    // Only the fields the form changed are written, so a folder or keyword a pull brought in meanwhile stays.
    func apply(
        to query: inout SavedQuery,
        changedSince opening: SavedQueryDraft,
        connectionId: UUID,
        folders: [SavedQueryFolder]
    ) {
        if trimmedName != opening.trimmedName {
            query.name = trimmedName
        }
        if normalizedKeyword != opening.normalizedKeyword {
            query.keyword = normalizedKeyword
        }
        if isGlobal != opening.isGlobal {
            query.connectionId = scope(in: connectionId)
        }
        if folderId != opening.folderId {
            query.folderId = folderId
        }
        // A placement the Mac made before the scope rule stays until this form moves or rescopes the query.
        guard isGlobal != opening.isGlobal || folderId != opening.folderId,
              let heldId = query.folderId,
              let folder = folders.first(where: { $0.id == heldId }),
              !SavedQueryScopeRule.folder(folder.connectionId, canHold: query.connectionId)
        else { return }
        query.folderId = nil
    }
}

nonisolated enum SavedQueryWriteFailure: Equatable, Sendable {
    case queryDeleted
    case folderDeleted
    case notSaved

    static func failedQueryWrite(_ id: UUID, in queries: [SavedQuery]) -> SavedQueryWriteFailure {
        queries.contains { $0.id == id } ? .notSaved : .queryDeleted
    }

    static func failedFolderWrite(_ id: UUID, in folders: [SavedQueryFolder]) -> SavedQueryWriteFailure {
        folders.contains { $0.id == id } ? .notSaved : .folderDeleted
    }

    var title: String {
        switch self {
        case .queryDeleted:
            String(localized: "Saved Query Deleted")
        case .folderDeleted:
            String(localized: "Folder Deleted")
        case .notSaved:
            String(localized: "Change Not Saved")
        }
    }

    var message: String {
        switch self {
        case .queryDeleted:
            String(localized: "This saved query no longer exists. It may have been removed from another device.")
        case .folderDeleted:
            String(localized: "This folder no longer exists. It may have been removed from another device.")
        case .notSaved:
            String(localized: "TablePro could not write your saved queries, so this change was not saved.")
        }
    }
}

nonisolated enum SavedQueryPreview {
    static let maximumLength = 50

    // Bounded scan: a saved query can be one 900 KB line, and every row draws its preview.
    static func firstLine(of sql: String) -> String? {
        let text = sql as NSString
        let length = text.length
        let content = CharacterSet.whitespacesAndNewlines.inverted
        var position = 0
        while position < length {
            let start = text.rangeOfCharacter(
                from: content,
                options: [],
                range: NSRange(location: position, length: length - position)
            ).location
            guard start != NSNotFound else { return nil }

            if text.substring(with: NSRange(location: start, length: min(2, length - start))) == "--" {
                let lineBreak = text.rangeOfCharacter(
                    from: .newlines,
                    options: [],
                    range: NSRange(location: start, length: length - start)
                ).location
                guard lineBreak != NSNotFound else { return nil }
                position = lineBreak + 1
                continue
            }

            let window = NSRange(location: start, length: min(maximumLength, length - start))
            let lineBreak = text.rangeOfCharacter(from: .newlines, options: [], range: window).location
            var end = lineBreak == NSNotFound ? NSMaxRange(window) : lineBreak
            if end < length {
                let lastCharacter = text.rangeOfComposedCharacterSequence(at: end - 1)
                if NSMaxRange(lastCharacter) > end {
                    end = lastCharacter.location
                }
            }
            return text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
