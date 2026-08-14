// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Liuke",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Liuke",
            path: "Sources/Liuke"
        )
    ]
)
