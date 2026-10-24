// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macompiz",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "macompiz",
            path: "Sources/macompiz",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
