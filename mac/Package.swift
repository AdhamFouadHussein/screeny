// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "screeny",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CVirtualDisplay"),
        .executableTarget(name: "screeny", dependencies: ["CVirtualDisplay"]),
    ]
)
