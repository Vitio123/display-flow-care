// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayFlow",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "DisplayFlow",
            path: "Sources/DisplayFlow",
            linkerSettings: [
                // Embed Info.plist into the binary so the system shows our
                // CFBundleName + NSCameraUsageDescription on the permission prompt.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
