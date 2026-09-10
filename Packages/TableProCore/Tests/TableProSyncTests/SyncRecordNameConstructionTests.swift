import Foundation
import Testing

@Suite("Record names are only built where CloudKit's length limit is enforced")
struct SyncRecordNameConstructionTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceRoots = [
        "TablePro",
        "TableProMobile/TableProMobile",
        "Packages/TableProCore/Sources"
    ]

    private static let permittedPaths: Set<String> = [
        "TablePro/Core/Sync/SyncRecordMapper.swift",
        "Packages/TableProCore/Sources/TableProSync/SyncRecordMapper.swift"
    ]

    @Test("Every source root the check covers is where the check expects it")
    func sourceRootsExist() {
        for path in Self.sourceRoots {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), """
            \(path) has moved, so this check would pass vacuously. Update sourceRoots.
            """)
        }
    }

    @Test("Every mapper the check permits is where the check expects it")
    func permittedMappersExist() {
        for path in Self.permittedPaths {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), """
            \(path) has moved. Update permittedPaths.
            """)
        }
    }

    @Test("No shipping source constructs a CKRecord.ID outside the mappers")
    func recordIdsComeFromTheMappers() {
        var offenders: [String] = []

        for root in Self.sourceRoots {
            let rootURL = Self.repositoryRoot.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let url as URL in files where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
                guard !Self.permittedPaths.contains(path),
                      let source = try? String(contentsOf: url, encoding: .utf8) else { continue }

                for (offset, line) in source.components(separatedBy: .newlines).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), code.contains("CKRecord.ID(recordName:") else { continue }
                    offenders.append("\(path):\(offset + 1): \(code)")
                }
            }
        }

        #expect(offenders.isEmpty, """
        CKRecord.ID(recordName:) raises CKException past 255 UTF-16 code units, and an \
        Objective-C exception raised inside a Swift task crashes the app from an unrelated call \
        site seconds later. SyncRecordType.recordName(for:) is the only thing that bounds the \
        name, so go through SyncRecordMapper.recordID(type:id:in:).
        \(offenders.joined(separator: "\n"))
        """)
    }
}
