// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        // A source editor with useful features for code editing.
        .library(
            name: "CodeEditSourceEditor",
            targets: ["CodeEditSourceEditor"]
        )
    ],
    dependencies: [
        // A fast, efficient, text view for code (local override).
        .package(path: "../CodeEditTextView"),
        // tree-sitter languages (local override)
        .package(path: "../CodeEditLanguages"),
        // CodeEditSymbols
        .package(
            url: "https://github.com/CodeEditApp/CodeEditSymbols.git",
            exact: "0.2.3"
        ),
        // SwiftLint
        .package(
            url: "https://github.com/lukepistrol/SwiftLintPlugin",
            from: "0.2.2"
        ),
        // Rules for indentation, pair completion, whitespace
        .package(
            url: "https://github.com/ChimeHQ/TextFormation",
            from: "0.8.2"
        ),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0")
    ],
    targets: [
        // A source editor with useful features for code editing.
        .target(
            name: "CodeEditSourceEditor",
            dependencies: [
                "CodeEditTextView",
                "CodeEditLanguages",
                "TextFormation",
                "CodeEditSymbols"
            ],
            plugins: [
                .plugin(name: "SwiftLint", package: "SwiftLintPlugin")
            ]
        ),

        // Tests for the source editor
        .testTarget(
            name: "CodeEditSourceEditorTests",
            dependencies: [
                "CodeEditSourceEditor",
                "CodeEditLanguages",
                .product(name: "CustomDump", package: "swift-custom-dump")
            ],
            plugins: [
                .plugin(name: "SwiftLint", package: "SwiftLintPlugin")
            ]
        ),
    ]
)
