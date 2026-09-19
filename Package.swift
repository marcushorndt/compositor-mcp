// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "compositor-mcp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "compositor-mcp", targets: ["compositor-mcp"]),
    ],
    targets: [
        // Compositor's C pixel routines, compiled as their own module.
        .target(name: "CompositorC", publicHeadersPath: "include"),

        // Sources/compositor-mcp/Upstream holds symlinks to Compositor's own
        // document, IO and rendering sources. They compile unmodified: the
        // bridging header reproduces the app target's setup. The server code in
        // Server/ lives in the same module so it can use those internal types
        // without patching `public` onto upstream files.
        .executableTarget(
            name: "compositor-mcp",
            dependencies: ["CompositorC"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-import-objc-header", "Bridging/Bridging.h",
                    "-Xcc", "-ISources/CompositorC/include",
                ]),
            ]
        ),
    ]
)
