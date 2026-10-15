// swift-tools-version: 6.0
//
// Overblast feedback reports for Apple platforms.
//
// TWO PRODUCTS, AND THE CORE IS FOUNDATION ONLY. `OverblastFeedbackCore` is the payload, its limits,
// the redaction, the log ring buffer, the HTTP client and the pending-report store: everything that
// has nothing to do with a screen, so it builds and is tested on a Mac with `swift test`.
// `OverblastFeedback` is the UI half (the frozen screenshot, tap-to-select, the sheet, and shake on an
// iPhone or iPad) and re-exports the core, so an app imports one module and gets both. It is UIKit on
// iOS, iPadOS and visionOS and AppKit on macOS, behind one API. Neither has any dependency.
import PackageDescription

let package = Package(
  name: "OverblastFeedback",
  platforms: [
    // The UI needs iOS 15 (`OSLogStore` for the app's own process, sheet detents) and macOS 13
    // (`NSHostingController.sizingOptions`, which sizes the sheet to its content). macOS is also
    // where `swift test` runs the core without a simulator. visionOS 1 is the first there is; it has
    // no shake, so there the sheet opens from a button.
    .iOS(.v15),
    .macOS(.v13),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "OverblastFeedback", targets: ["OverblastFeedback"]),
    .library(name: "OverblastFeedbackCore", targets: ["OverblastFeedbackCore"]),
  ],
  targets: [
    // The privacy manifest travels with the core, which is the target that touches UserDefaults; it
    // is copied into the core's resource bundle on every platform.
    .target(name: "OverblastFeedbackCore", resources: [.copy("PrivacyInfo.xcprivacy")]),
    .target(name: "OverblastFeedback", dependencies: ["OverblastFeedbackCore"]),
    .testTarget(name: "OverblastFeedbackCoreTests", dependencies: ["OverblastFeedbackCore"]),
    // The UI half's tests: element picking, masking, the screenshot, the shake hook. The UIKit ones run
    // under `xcodebuild test` on an iOS or visionOS simulator; the AppKit ones run under `swift test`
    // on a Mac, beside the core's.
    .testTarget(name: "OverblastFeedbackTests", dependencies: ["OverblastFeedback"]),
    // THE SAMPLE IS A TARGET AND NOT A PRODUCT, as in the sponsoredtokens SDK: it is compiled on
    // every build, so it cannot quietly stop matching the API it demonstrates, and nobody can depend
    // on it by accident. It is SwiftUI, so the same file compiles for iOS, visionOS and macOS.
    .target(name: "FeedbackSample", dependencies: ["OverblastFeedback"], path: "Samples/FeedbackSample"),
  ],
  swiftLanguageModes: [.v6]
)
