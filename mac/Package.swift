// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Burnrate",
    platforms: [.macOS(.v26)],
    targets: [
        // the data engine, shared by the app and burnratectl; no SwiftUI here
        .target(name: "BurnrateCore"),
        .executableTarget(name: "Burnrate", dependencies: ["BurnrateCore"]),
        // check | init | dump: the engine from the terminal, no window
        .executableTarget(name: "burnratectl", dependencies: ["BurnrateCore"]),
        // desktop widget; build-app.sh packs it as Contents/PlugIns/BurnrateWidget.appex
        .executableTarget(
            name: "BurnrateWidget",
            dependencies: ["BurnrateCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            // extensions start in Foundation's NSExtensionMain, like Xcode links them;
            // the Swift main of a WidgetBundle alone just returns and the process exits
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("WidgetKit"),
            ]
        ),
        .testTarget(
            name: "BurnrateCoreTests",
            dependencies: ["BurnrateCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
