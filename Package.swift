// swift-tools-version: 5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "NearbyAudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "nearby-audio", targets: ["NearbyAudioMac"])],
    targets: [
        .target(name: "NativePAKE", path: "NativePAKE", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(root)/local/boringssl/include"])],
                linkerSettings: [.unsafeFlags(["\(root)/local/boringssl-macos/libcrypto.a", "-lc++"])]),
        .target(name: "NearbyAudioCore", dependencies: ["NativePAKE"], path: "Shared"),
        .executableTarget(name: "NearbyAudioMac", dependencies: ["NearbyAudioCore"], path: "Mac"),
        .testTarget(name: "NearbyAudioCoreTests", dependencies: ["NearbyAudioCore"], path: "Tests"),
    ]
)
