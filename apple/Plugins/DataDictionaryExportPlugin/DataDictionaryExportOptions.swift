//
//  DataDictionaryExportOptions.swift
//  DataDictionaryExportPlugin
//

import Foundation

public enum DataDictionaryFileType: String, Codable, CaseIterable, Sendable {
    case markdown
    case html

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        }
    }
}

public struct DataDictionaryExportOptions: Equatable, Codable {
    public var fileType: DataDictionaryFileType = .markdown

    public init() {}

    // A synthesized decoder throws on a key the saved payload predates instead of using the default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileType = (try? container.decodeIfPresent(DataDictionaryFileType.self, forKey: .fileType))
            ?? DataDictionaryExportOptions().fileType
    }
}
