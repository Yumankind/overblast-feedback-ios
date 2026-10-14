// swift-tools-version: 6.0
//
// Overblast feedback reports for Apple platforms.
//
// TWO PRODUCTS, AND THE CORE IS FOUNDATION ONLY. `OverblastFeedbackCore` is the payload, its limits,
// the redaction, the log ring buffer, the HTTP client and the pending-report store: everything that
// has nothing to do with a screen, so it builds and is tested on a Mac with `swift test`.
// `OverblastFeedback` is the UIKit half (shake, the frozen screenshot, tap-to-select, the sheet) and
// re-exports the core, so an app imports one module and gets both. Neither has any dependency.
import PackageDescription

let package = Package(
  name: "OverblastFeedback",
  platforms: [
    // The UI needs iOS 15 (`OSLogStore` for the app's own process, sheet detents). The core also
    // builds for macOS 13 so `swift test` runs on a developer's Mac without a simulator.
    .iOS(.v15),
    .macOS(.v13),
  ],
  products: [
    .library(name: "OverblastFeedback", targets: ["OverblastFeedback"]),
    .library(name: "OverblastFeedbackCore", targets: ["OverblastFeedbackCore"]),
  ],
  targets: [
    .target(name: "OverblastFeedbackCore"),
    .target(name: "OverblastFeedback", dependencies: ["OverblastFeedbackCore"]),
    .testTarget(name: "OverblastFeedbackCoreTests", dependencies: ["OverblastFeedbackCore"]),
    // The UIKit half's tests: element picking, masking, the screenshot, the shake hook. They run under
    // `xcodebuild test` on a simulator and compile to nothing under `swift test` on a Mac.
    .testTarget(name: "OverblastFeedbackTests", dependencies: ["OverblastFeedback"]),
    // THE SAMPLE IS A TARGET AND NOT A PRODUCT, as in the sponsoredtokens SDK: it is compiled on
    // every build, so it cannot quietly stop matching the API it demonstrates, and nobody can depend
    // on it by accident. Everything in it is behind `#if canImport(UIKit)`, so on a Mac it is empty.
    .target(name: "FeedbackSample", dependencies: ["OverblastFeedback"], path: "Samples/FeedbackSample"),
  ],
  swiftLanguageModes: [.v6]
)
