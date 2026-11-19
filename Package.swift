// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProcXRay",
    platforms: [.macOS("15.0")],
    targets: [
        // C shim for the variadic sandbox_check, which Swift can't call itself.
        .target(name: "CSandbox", path: "Sources/CSandbox"),
        // pxr-exec: sets what posix_spawn can't (rlimits, umask, nice, I/O policy, a sandbox), then execs the
        // program in place (Launcher). Shipped next to ProcXRay in Contents/MacOS.
        .executableTarget(name: "pxr-exec", path: "Sources/PXRExec"),
        .executableTarget(
            name: "ProcXRay",
            dependencies: ["CSandbox"],
            path: "Sources/ProcXRay",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("AppKit"), .linkedFramework("IOKit"), .linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ProcXRayTests", dependencies: ["ProcXRay"])
    ]
)
