#if canImport(UIKit)
import OverblastFeedback
import SwiftUI

/// The whole integration, in one file: start, the reporter, a private view, a log line, and a
/// button for people who will never think to shake their phone.
///
/// It is a LIBRARY TARGET and not an app, as in the sponsoredtokens SDK: it is compiled on every
/// build so it cannot drift from the API, and it needs no bundle id or signing to do that. To run it,
/// make an iOS app in Xcode, add this package, and use `FeedbackSampleApp`'s body as your own:
///
/// ```swift
/// @main struct MyApp: App {
///   init() { FeedbackSample.start() }
///   var body: some Scene { WindowGroup { CartScreen() } }
/// }
/// ```
public enum FeedbackSample {
  /// Call once at launch.
  @MainActor
  public static func start() {
    OverblastFeedback.start(
      key: "obfk_REPLACEWITHYOURKEY000000",       // the console's Feedback keys page
      options: FeedbackOptions(extra: ["plan": "pro"])
    )
    // After your own sign-in. With an email, the sheet does not ask for one, and the team can reply.
    OverblastFeedback.setReporter(email: nil, name: "Ana", accountRef: "cus_8812")
    OverblastFeedback.info("app launched")
  }
}

/// A screen with something private on it.
public struct CartScreen: View {
  @State private var items = ["Coffee beans", "Filter papers", "Grinder"]

  public init() {}

  public var body: some View {
    NavigationView {
      List {
        Section("Cart") {
          ForEach(items, id: \.self) { item in
            HStack {
              Text(item)
              Spacer()
              Button("Remove") {
                items.removeAll { $0 == item }
                OverblastFeedback.log(.info, "removed \(item)")
              }
              // SwiftUI publishes no view hierarchy to point at unless VoiceOver is on; this makes the
              // button selectable by name in every report.
              .overblastElement("cart.remove")
            }
          }
        }
        Section("Payment") {
          // Never in a screenshot, whatever the reporter chooses.
          Text("Visa ending 4242")
            .overblastPrivate()
          SecureField("Card PIN", text: .constant(""))   // secure fields are blanked always
        }
        Section {
          Button("Report a problem") { OverblastFeedback.present() }
        }
      }
      .navigationTitle("Your cart")
    }
  }
}
#endif
