// swift-tools-version: 6.0

import PackageDescription

// Keep generated bindings and their binary together so their UniFFI checksums agree.
let package = Package(
    name: "TableProFFI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TableProFFI", targets: ["TableProFFI"])
    ],
    targets: [
        .binaryTarget(name: "TableProFFIC", path: "Build/TableProFFIC.xcframework"),
        .target(
            name: "TableProFFI",
            dependencies: ["TableProFFIC"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(name: "TableProFFITests", dependencies: ["TableProFFI"])
    ]
)
