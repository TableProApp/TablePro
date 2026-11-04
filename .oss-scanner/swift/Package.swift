// swift-tools-version: 6.0

// The apple/Packages/TableProCore targets that compile on Linux. The rest need Apple frameworks.
// .oss-scanner/Dockerfile links each target's folder in from TableProCore by name.
import PackageDescription

let package = Package(
    name: "TableProCoreLinux",
    targets: [
        .target(name: "TableProSQLQuoting"),
        .target(name: "TableProProcess"),
        .target(name: "TableProSQLGrammar", dependencies: ["TableProSQLQuoting"]),
        .target(name: "CSQLite"),
        .target(name: "TableProSQLiteCore", dependencies: ["CSQLite"]),
        .target(name: "TableProLogRedaction"),
        .target(name: "TableProCoreTypes"),
        .target(name: "TableProDocumentPath"),
        .target(name: "TableProJavaScriptText"),
        .target(name: "TableProDamengCore", dependencies: ["TableProSQLGrammar"]),
        .target(name: "TableProWireIO"),
        .target(name: "TableProCassandraCore", dependencies: ["TableProSQLGrammar", "TableProSQLQuoting"]),
        .testTarget(name: "TableProSQLGrammarTests", dependencies: ["TableProSQLGrammar"]),
        .testTarget(
            name: "TableProSQLQuotingTests",
            dependencies: ["TableProSQLQuoting", "TableProSQLGrammar", "CSQLite"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "TableProLogRedactionTests", dependencies: ["TableProLogRedaction"]),
        .testTarget(name: "TableProProcessTests", dependencies: ["TableProProcess"]),
        .testTarget(name: "TableProDamengCoreTests", dependencies: ["TableProDamengCore", "TableProSQLGrammar"]),
        .testTarget(name: "TableProWireIOTests", dependencies: ["TableProWireIO"]),
        .testTarget(name: "TableProCassandraCoreTests", dependencies: ["TableProCassandraCore", "TableProSQLGrammar"])
    ]
)
