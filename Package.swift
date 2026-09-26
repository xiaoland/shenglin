// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NearbyAudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "nearby-audio", targets: ["NearbyAudioMac"])],
    targets: [
        .target(name: "NearbyAudioCore", path: "Shared"),
        .executableTarget(name: "NearbyAudioMac", dependencies: ["NearbyAudioCore"], path: "Mac"),
        .testTarget(name: "NearbyAudioCoreTests", dependencies: ["NearbyAudioCore"], path: "Tests"),
    ]
)
