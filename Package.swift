// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "compositor-mcp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "compositor-mcp", targets: ["compositor-mcp"]),
        // Shared with Compositor's own "Generate Layer" panel.
        .library(name: "ContentMaschineKit", targets: ["ContentMaschineKit"]),
    ],
    targets: [
        // Compositor's C pixel routines, compiled as their own module.
        .target(name: "CompositorC", publicHeadersPath: "include"),

        // The ContentMaschine API client. No UI and no Compositor types, so the
        // app can compile the same file.
        .target(name: "ContentMaschineKit"),

        // Sources/compositor-mcp/Upstream holds symlinks to Compositor's own
        // document, IO and rendering sources. They compile unmodified because the
        // settings below reproduce the app target's: the bridging header, Swift 5
        // mode, MainActor as the default isolation, Approachable Concurrency and
        // member import visibility (see Compositor.xcodeproj). The server code in
        // Server/ lives in the same module so it can use those internal types
        // without patching `public` onto upstream files.
        .executableTarget(
            name: "compositor-mcp",
            dependencies: ["CompositorC", "ContentMaschineKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
                .defaultIsolation(MainActor.self),
                // SWIFT_APPROACHABLE_CONCURRENCY = YES
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                // SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES
                .enableUpcomingFeature("MemberImportVisibility"),
                .unsafeFlags([
                    "-import-objc-header", "Bridging/Bridging.h",
                    "-Xcc", "-ISources/CompositorC/include",
                ]),
            ]
        ),
    ]
)
