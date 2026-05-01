// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ScreenMirrorServer",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ScreenMirrorServer",
            path: "Sources/ScreenMirrorServer"
        )
    ]
)
