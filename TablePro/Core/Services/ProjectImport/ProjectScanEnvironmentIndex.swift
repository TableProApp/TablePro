//
//  ProjectScanEnvironmentIndex.swift
//  TablePro
//

import Foundation

enum ProjectFileReader {
    static func text(at url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    static func data(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

struct ProjectScanEnvironmentIndex {
    private var documentsByFile: [String: DotenvDocument] = [:]
    private var documentsByDirectory: [String: DotenvDocument] = [:]
    private var rootDocument: DotenvDocument?

    init(files: [ProjectScanFile], rootURL: URL) {
        let rootPath = rootURL.standardizedFileURL.path
        for file in files where file.match.kind == .dotenv {
            guard let contents = ProjectFileReader.text(at: file.url) else {
                continue
            }
            let document = DotenvParser.parse(contents)
            let filePath = file.url.standardizedFileURL.path
            let directory = file.url.deletingLastPathComponent().standardizedFileURL.path
            documentsByFile[filePath] = document
            if documentsByDirectory[directory] == nil || file.match.tier == .nearCertain {
                documentsByDirectory[directory] = document
            }
            if directory == rootPath, rootDocument == nil || file.match.tier == .nearCertain {
                rootDocument = document
            }
        }
    }

    func document(forFile url: URL) -> DotenvDocument? {
        documentsByFile[url.standardizedFileURL.path]
    }

    func environment(near url: URL) -> DotenvDocument? {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        return documentsByDirectory[directory] ?? rootDocument
    }
}
