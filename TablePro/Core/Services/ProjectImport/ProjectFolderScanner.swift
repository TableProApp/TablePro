//
//  ProjectFolderScanner.swift
//  TablePro
//

import Foundation
import os

enum ProjectFolderScanError: Error, LocalizedError, Equatable {
    case rootUnreadable

    var errorDescription: String? {
        switch self {
        case .rootUnreadable:
            return String(localized: "That folder could not be read.")
        }
    }
}

struct ProjectFolderScanResult {
    let candidates: [ScannedConnectionCandidate]
    let scannedFileCount: Int
}

enum ProjectFolderScanner {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ProjectFolderScanner")

    static func scan(
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> Result<ProjectFolderScanResult, ProjectFolderScanError> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.rootUnreadable)
        }
        let files = ProjectFolderFileWalker.walk(root: rootURL, fileManager: fileManager)
        let index = ProjectScanEnvironmentIndex(files: files, rootURL: rootURL)
        var candidates: [ScannedConnectionCandidate] = []
        for file in files {
            candidates.append(contentsOf: extract(
                file: file,
                rootURL: rootURL,
                index: index,
                fileManager: fileManager
            ))
        }
        candidates.append(contentsOf: parentWordPressCandidates(rootURL: rootURL, fileManager: fileManager))
        let ranked = ScannedConnectionRanking.rankAndDeduplicate(candidates)
        logger.info(
            "Scanned \(files.count, privacy: .public) config files, produced \(ranked.count, privacy: .public) candidates"
        )
        return .success(ProjectFolderScanResult(candidates: ranked, scannedFileCount: files.count))
    }

    private static func extract(
        file: ProjectScanFile,
        rootURL: URL,
        index: ProjectScanEnvironmentIndex,
        fileManager: FileManager
    ) -> [ScannedConnectionCandidate] {
        let directoryURL = file.url.deletingLastPathComponent()
        switch file.match.kind {
        case .dotenv:
            guard let document = index.document(forFile: file.url) else {
                return []
            }
            return DotenvConnectionExtractor.extract(
                document: document,
                relativePath: file.relativePath,
                tier: file.match.tier,
                directoryURL: directoryURL
            )
        case .wordPressConfig:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return WordPressConfigExtractor.extract(contents: contents, relativePath: file.relativePath)
        case .prismaSchema:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return PrismaSchemaExtractor.extract(
                contents: contents,
                relativePath: file.relativePath,
                directoryURL: directoryURL,
                projectRootURL: rootURL,
                environment: index.environment(near: file.url),
                fileManager: fileManager
            )
        case .springProperties:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return SpringPropertiesExtractor.extract(contents: contents, relativePath: file.relativePath)
        case .springYaml:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return SpringYamlExtractor.extract(contents: contents, relativePath: file.relativePath)
        case .appSettingsJson:
            guard let data = ProjectFileReader.data(at: file.url) else {
                return []
            }
            return AppSettingsJsonExtractor.extract(data: data, relativePath: file.relativePath)
        case .railsDatabaseYaml:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return RailsDatabaseYamlExtractor.extract(
                contents: contents,
                relativePath: file.relativePath,
                projectRootURL: rootURL,
                environment: index.environment(near: file.url)
            )
        case .dockerCompose:
            guard let contents = ProjectFileReader.text(at: file.url) else {
                return []
            }
            return DockerComposeExtractor.extract(
                contents: contents,
                relativePath: file.relativePath,
                environment: index.environment(near: file.url)
            )
        }
    }

    private static func parentWordPressCandidates(
        rootURL: URL,
        fileManager: FileManager
    ) -> [ScannedConnectionCandidate] {
        let parent = rootURL.standardizedFileURL.deletingLastPathComponent()
        let candidateURL = parent.appendingPathComponent("wp-config.php")
        let path = candidateURL.standardizedFileURL.path
        guard !ProjectFolderFileWalker.isDenied(path) else {
            return []
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? candidateURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= ProjectFolderFileWalker.maxFileSize else {
            return []
        }
        guard let contents = ProjectFileReader.text(at: candidateURL) else {
            return []
        }
        return WordPressConfigExtractor.extract(contents: contents, relativePath: "../wp-config.php")
    }
}
