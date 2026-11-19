import Foundation

extension QueryTab {
    var isNamedByUser: Bool {
        automaticTitle != nil
    }

    var automaticName: String {
        automaticTitle ?? title
    }

    // A file tab is named by its file, and every other kind by what it shows.
    var canBeRenamed: Bool {
        tabType == .query && content.sourceFileURL == nil
    }

    // The one test move, merge and reopen share: only a number the app handed out gives way to a repeat.
    var renumbersOnCollision: Bool {
        tabType == .query
            && automaticTitle == nil
            && content.sourceFileURL == nil
            && Self.isDefaultQueryTitle(title)
    }

    func repeatsTitle(of others: [QueryTab]) -> Bool {
        others.contains { $0.id != id && $0.tabType == .query && $0.title == title }
    }

    // A linked file takes over only a tab holding nothing of the user's, a name included.
    var canAdoptLinkedFile: Bool {
        tabType == .query
            && content.sourceFileURL == nil
            && !isNamedByUser
            && content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isDefaultQueryTitle(_ title: String) -> Bool {
        defaultQueryNumber(in: title) != nil
    }

    static func defaultQueryNumber(in title: String) -> Int? {
        guard title.hasPrefix("Query ") else { return nil }
        return Int(title.dropFirst(6))
    }

    // A typed name can hold a path separator or end in the extension already.
    static func suggestedSaveName(forTitle title: String) -> String {
        let name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.lowercased().hasSuffix(".sql") else { return name }
        return "\(name).sql"
    }
}
