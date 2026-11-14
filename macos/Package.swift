// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoxyVPNMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FoxyVPN", targets: ["FoxyVPN"]),
        .executable(name: "foxyvpn-tunnel", targets: ["TunnelHelper"]),
        .executable(name: "foxyvpn-relay", targets: ["RelayHelper"])
    ],
    targets: [
        .target(name: "FoxyCore"),
        .executableTarget(name: "FoxyVPN", dependencies: ["FoxyCore"]),
        .executableTarget(name: "TunnelHelper", dependencies: ["FoxyCore"]),
        .executableTarget(name: "RelayHelper"),
        .testTarget(name: "FoxyCoreTests", dependencies: ["FoxyCore"]),
        .testTarget(name: "FoxyVPNTests", dependencies: ["FoxyVPN"])
    ]
)
