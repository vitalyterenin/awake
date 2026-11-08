// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Awake", targets: ["Awake"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "AwakeCore"),
        .target(name: "AwakeRuntime", dependencies: ["AwakeCore"]),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore"]),
        .testTarget(name: "AwakeRuntimeTests", dependencies: ["AwakeRuntime", "AwakeCore"]),
        .executableTarget(name: "Awake", dependencies: [
            "AwakeCore", "AwakeRuntime", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
