// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "disproid",
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
            name: "disproid",
            dependencies: ["CGVirtualDisplayInterface"],
            linkerSettings: [
                // CGVirtualDisplay クラス群は CoreGraphics に含まれる（実機 introspection で確認済み）。
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
