// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UserForge",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UserForgeCore"),
        .executableTarget(name: "userforge", dependencies: ["UserForgeCore"]),
        .executableTarget(name: "UserForgeApp", dependencies: ["UserForgeCore"]),
    ]
)
