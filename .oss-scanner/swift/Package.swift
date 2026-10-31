// swift-tools-version: 6.0

// The apple/Packages/TableProCore targets that compile on Linux. The rest need Apple frameworks.
// .oss-scanner/Dockerfile links each target's folder in from TableProCore by name.
import PackageDescription

let package = Package(
    name: "TableProCoreLinux",
    targets: [
        .target(name: "TableProSQLGrammar"),
        .target(name: "CSQLite"),
        .target(name: "TableProSQLiteCore", dependencies: ["CSQLite"]),
        .target(name: "TableProLogRedaction"),
        .target(name: "TableProCoreTypes"),
        .target(name: "TableProDocumentPath"),
        .target(name: "TableProJavaScriptText"),
        .target(name: "TableProDamengCore", dependencies: ["TableProSQLGrammar"]),
        .testTarget(name: "TableProSQLGrammarTests", dependencies: ["TableProSQLGrammar"]),
        .testTarget(name: "TableProLogRedactionTests", dependencies: ["TableProLogRedaction"]),
        .testTarget(name: "TableProDamengCoreTests", dependencies: ["TableProDamengCore", "TableProSQLGrammar"])
    ]
)
