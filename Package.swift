// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vm-sandbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "vmsandbox", targets: ["vmsandbox"]),
        .executable(name: "sandbox-mcp", targets: ["sandbox-mcp"]),
    ],
    targets: [
        .target(name: "SandboxKit"),
        .executableTarget(
            name: "vmsandbox",
            dependencies: ["SandboxKit"],
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
        .executableTarget(name: "sandbox-mcp", dependencies: ["SandboxKit"]),
        .testTarget(name: "SandboxKitTests", dependencies: ["SandboxKit"]),
    ]
)
