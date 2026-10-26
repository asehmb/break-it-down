// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BreakItDown",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BreakItDown",
            path: "Sources/BreakItDown"
        )
    ]
)
