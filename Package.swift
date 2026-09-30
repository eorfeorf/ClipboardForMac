// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardForMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClipboardForMac", targets: ["ClipboardForMac"])],
    targets: [
        .executableTarget(
            name: "ClipboardForMac",
            path: "Sources/ClipboardForMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "ClipboardForMacTests",
            dependencies: ["ClipboardForMac"],
            path: "Tests/ClipboardForMacTests"
        )
    ]
)
