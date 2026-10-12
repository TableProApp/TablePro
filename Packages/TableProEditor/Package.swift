// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TableProEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TableProEditorKit", targets: ["TableProEditorKit"]),
        .library(name: "TableProTextEngine", targets: ["TableProTextEngine"])
    ],
    dependencies: [
        .package(path: "../TableProGrammars"),
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.8.2"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        .target(
            name: "TableProTextEngineObjC",
            publicHeadersPath: "include",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TableProTextEngine",
            dependencies: [
                "TableProTextEngineObjC",
                "TextStory",
                .product(name: "Collections", package: "swift-collections")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TableProEditorKit",
            dependencies: [
                "TableProTextEngine",
                "TableProGrammars",
                "TextFormation"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TableProTextEngineTests",
            dependencies: ["TableProTextEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TableProEditorKitTests",
            dependencies: [
                "TableProEditorKit",
                "TableProGrammars"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
