// swift-tools-version:6.0
// 2ndMind v2 — native second brain. See Efforts/Active/2ndmind-v2/PLAN.md.
import PackageDescription

let package = Package(
    name: "secondmind",
    platforms: [.macOS(.v15)],
    products: [
        // The menu-bar app binary is named `2ndm1nd` — this is the name macOS
        // shows in the Privacy & Security (TCC) permission list.
        .executable(name: "2ndm1nd", targets: ["SecondMindApp"]),
        .executable(name: "brain", targets: ["BrainCLI"]),
        .library(name: "SecondMindKit", targets: ["SecondMindKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SecondMindKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "SecondMindApp",
            dependencies: ["SecondMindKit"],
            exclude: ["Info.plist"],   // consumed by the linker (sectcreate), not a resource
            // Embed Info.plist into the bare executable (__TEXT,__info_plist):
            // TCC refuses to present Calendar/Reminders/Contacts prompts without
            // usage strings, and a SwiftPM binary has no bundle to carry them.
            // Same binary path + stable cert ⇒ existing TCC grants survive.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SecondMindApp/Info.plist",
                ])
            ]
        ),
        .executableTarget(name: "BrainCLI", dependencies: ["SecondMindKit"]),
        .testTarget(name: "SecondMindKitTests", dependencies: ["SecondMindKit"]),
    ]
)
