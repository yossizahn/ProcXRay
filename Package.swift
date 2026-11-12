// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProcXRay",
    platforms: [.macOS(.v14)],
    targets: [
        // C shim for the variadic sandbox_check, which Swift can't call itself.
        .target(name: "CSandbox", path: "Sources/CSandbox"),
        .executableTarget(
            name: "ProcXRay",
            dependencies: ["CSandbox"],
            path: "Sources/ProcXRay",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("AppKit"), .linkedFramework("IOKit")]
        )
    ]
)
