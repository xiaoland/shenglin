// swift-tools-version: 5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Shenglin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "shenglin", targets: ["ShenglinMac"])],
    targets: [
        .target(name: "NativePAKE", path: "NativePAKE", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I\(root)/local/boringssl/include"])],
                linkerSettings: [.unsafeFlags(["\(root)/local/boringssl-macos/libcrypto.a", "-lc++"])]),
        .target(name: "ShenglinCore", dependencies: ["NativePAKE"], path: "Shared"),
        .executableTarget(name: "ShenglinMac", dependencies: ["ShenglinCore"], path: "Mac"),
        .testTarget(name: "ShenglinCoreTests", dependencies: ["ShenglinCore"], path: "Tests"),
    ]
)
