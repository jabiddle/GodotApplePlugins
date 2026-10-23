// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-internalize-at-link",
        "-Xfrontend", "-lto=llvm-full",
        "-Xfrontend", "-conditional-runtime-records"
    ])
]

let linkerSettings: [LinkerSetting] = [
    // -ObjC: FirebaseAnalytics requires it (firebase-ios-sdk SwiftPackageManager.md). Without it the
    // linker drops any static-archive object file that holds only an Objective-C category, and the
    // first call into one is an unrecognized-selector abort on com.google.fira.worker at runtime.
    .unsafeFlags(["-Xlinker", "-ObjC", "-Xlinker", "-dead_strip"])
]

let package = Package(
    name: "GodotApplePlugins",
    platforms: [
        .iOS(.v18),
        .macOS("14.0"),
    ],
    products: [
        .library(
            name: "GodotApplePlugins",
            type: .dynamic,
            targets: ["GodotApplePlugins"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", revision: "61f258c8a679ca8e2b637befb77daf1a640a5349"),
        // For local development:
        //.package(path: "../SwiftGodot")

        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", .upToNextMajor(from: "12.18.0")),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        .target(
            name: "GodotApplePlugins",
            dependencies: [
                .product(name: "SwiftGodotRuntimeStatic", package: "SwiftGodot"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                "ScreenTimeCore",
                "FirestoreValueCore"
            ],
            exclude: [
                "GameCenter/GameCenterGuide.md",
                "GameCenter/Entitlements.md",
                "ScreenTime/Core",
                "Firebase/Core"
            ],
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),
        // Foundation and the Screen Time frameworks only: app extensions compile these same files,
        // and the activity monitor runs in 6 MB.
        .target(
            name: "ScreenTimeCore",
            path: "Sources/GodotApplePlugins/ScreenTime/Core"
        ),
        .testTarget(
            name: "ScreenTimeCoreTests",
            dependencies: ["ScreenTimeCore"]
        ),
        // Foundation only, so how a Firestore value maps onto a Godot type is tested on the host.
        .target(
            name: "FirestoreValueCore",
            path: "Sources/GodotApplePlugins/Firebase/Core"
        ),
        .testTarget(
            name: "FirestoreValueCoreTests",
            dependencies: ["FirestoreValueCore"]
        ),
    ]
)
