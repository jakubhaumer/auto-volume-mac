// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "auto-volume",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "auto-volume", targets: ["auto-volume"]),
    ],
    targets: [
        .target(name: "AutoVolumeCore"),
        .executableTarget(
            name: "auto-volume",
            dependencies: ["AutoVolumeCore"]
        ),
        .executableTarget(
            name: "leveler-check",
            dependencies: ["AutoVolumeCore"]
        ),
    ]
)
