// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TableProGrammars",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TableProGrammars", targets: ["TableProGrammars"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "TreeSitterGrammars",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("vendored-headers")]
        ),
        .target(
            name: "TableProGrammars",
            dependencies: [
                "TreeSitterGrammars",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")
            ],
            resources: [.copy("Queries")]
        ),
        .testTarget(
            name: "TableProGrammarsTests",
            dependencies: ["TableProGrammars"]
        )
    ]
)
