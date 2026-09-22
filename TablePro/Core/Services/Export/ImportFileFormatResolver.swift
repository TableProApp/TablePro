//
//  ImportFileFormatResolver.swift
//  TablePro
//

import Foundation
import UniformTypeIdentifiers

enum ImportFileFormatMatch: Equatable {
    case format(String)

    /// A `.gz` whose inner suffix names a format that cannot read a compressed file. Only the
    /// statement importer decompresses, so `orders.csv.gz` has to be refused by name rather than
    /// handed to it and parsed as SQL.
    case compressedRowFormat(formatId: String)

    /// More than one offered format reads the extension. Answering by name is the point: picking
    /// whichever the driver happens to offer first is the shape this type exists to remove.
    case ambiguous(formatIds: [String])

    case unrecognized
}

/// Which importer a chosen file belongs to.
///
/// The format is a property of the file, not of the command that opened the panel. Resolving it
/// ahead of the panel is what made **Import Data…** a permanent alias for the first format the
/// driver offers, which the sort pins to SQL on every connection (#3047).
///
/// Dispatch is on the lowercased path extension and never on `UTType` conformance. Measured on
/// macOS 27: `jsonl` has no declared type at all, `public.ndjson` does not conform to `public.json`,
/// and `public.tab-separated-values-text` does not conform to
/// `public.comma-separated-values-text`, so conformance splits formats their own plugin treats
/// alike.
enum ImportFileFormatResolver {
    static let compressedFileExtension = "gz"

    /// What the panel enables. `allowedContentTypes` is not a gate, so this narrows the list a user
    /// browses rather than deciding what the app accepts; `ImportFilePanel` validates the result.
    static func contentTypes(for options: [ImportFormatOption]) -> [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        for option in options {
            for fileExtension in option.acceptedFileExtensions {
                guard let type = UTType(filenameExtension: fileExtension.lowercased()),
                      seen.insert(type.identifier).inserted
                else { continue }
                types.append(type)
            }
        }
        return types
    }

    /// Every extension any offered format reads, lowercased and deduplicated, in the order the
    /// formats are offered. This is what an error message names, so it stays stable.
    static func acceptedExtensions(for options: [ImportFormatOption]) -> [String] {
        var seen = Set<String>()
        var extensions: [String] = []
        for option in options {
            for fileExtension in option.acceptedFileExtensions {
                let lowercased = fileExtension.lowercased()
                guard seen.insert(lowercased).inserted else { continue }
                extensions.append(lowercased)
            }
        }
        return extensions
    }

    static func match(_ url: URL, among options: [ImportFormatOption]) -> ImportFileFormatMatch {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return .unrecognized }

        if fileExtension == compressedFileExtension {
            return matchCompressed(url, among: options)
        }
        return owner(of: fileExtension, among: options)
    }

    /// A `.gz` belongs to whichever format reads compressed files, which is what declaring `gz`
    /// means. The suffix underneath is read only to catch a file that plainly belongs elsewhere, so
    /// `orders.csv.gz` is refused by name rather than parsed as SQL. A suffix no format claims is
    /// not evidence of anything: `dump.v1.gz` is an ordinary dump name and stays with the
    /// compressed reader, as it did before the file decided the format.
    private static func matchCompressed(_ url: URL, among options: [ImportFormatOption]) -> ImportFileFormatMatch {
        let inner = innerSuffix(of: url)
        if case .format(let innerId) = owner(of: inner, among: options),
           let option = options.first(where: { $0.id == innerId }),
           !option.acceptedFileExtensions.contains(where: { $0.lowercased() == compressedFileExtension }) {
            return .compressedRowFormat(formatId: innerId)
        }
        return owner(of: compressedFileExtension, among: options)
    }

    /// Read off the name rather than `deletingPathExtension().pathExtension`, which is empty for a
    /// leading-dot name: measured, `.csv.gz` reports no inner extension at all and would otherwise
    /// pass as a compressed dump.
    private static func innerSuffix(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let suffix = ".\(compressedFileExtension)"
        guard name.hasSuffix(suffix) else { return "" }
        let stem = name.dropLast(suffix.count)
        return stem.split(separator: ".").last.map(String.init) ?? ""
    }

    private static func owner(of fileExtension: String, among options: [ImportFormatOption]) -> ImportFileFormatMatch {
        guard !fileExtension.isEmpty else { return .unrecognized }
        let owners = options.filter { option in
            option.acceptedFileExtensions.contains { $0.lowercased() == fileExtension }
        }
        if owners.isEmpty {
            return .unrecognized
        }
        if owners.count > 1 {
            return .ambiguous(formatIds: owners.map(\.id))
        }
        return .format(owners[0].id)
    }
}
