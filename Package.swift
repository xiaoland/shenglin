// swift-tools-version: 5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Shenglin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "shenglin", targets: ["ShenglinMac"])],
    targets: [
        .systemLibrary(name: "ShenglinRustFFI", path: "local/rust-bindings/swift"),
        .target(name: "ShenglinRust", dependencies: ["ShenglinRustFFI"], path: "local/rust-bindings/swift",
                exclude: ["ShenglinRustFFI.h", "ShenglinRustFFI.modulemap", "module.modulemap"],
                sources: ["ShenglinRust.swift"],
                linkerSettings: [.unsafeFlags(["\(root)/local/rust-target/aarch64-apple-darwin/release/libshenglin_core.a", "-lc++"])]),
        .target(name: "ShenglinCore", dependencies: ["ShenglinRust"], path: "Shared"),
        .executableTarget(name: "ShenglinMac", dependencies: ["ShenglinCore"], path: "Mac"),
        .testTarget(name: "ShenglinCoreTests", dependencies: ["ShenglinCore"], path: "Tests"),
    ]
)
