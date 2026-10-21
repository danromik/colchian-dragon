// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Colchian",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Colchian",
            path: "Sources/Colchian",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
