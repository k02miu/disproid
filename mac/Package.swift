// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "disproid-helper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 非公開 CGVirtualDisplay 系 Objective-C インターフェースの自前宣言。
        // 公開 SDK には存在しないため、ここで @interface を再現する。
        // 実体は CoreGraphics.framework に存在し、実行時に ObjC ランタイムで解決される。
        .target(
            name: "CGVirtualDisplayInterface"
        ),
        .executableTarget(
            name: "disproid-helper",
            dependencies: ["CGVirtualDisplayInterface"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost")
            ]
        )
    ]
)
