#if canImport(UIKit) || os(macOS)
import OverblastFeedback
import SwiftUI

/// The whole integration, in one file: start, the reporter, a private view, a log line, and the
/// Settings button, which is how the sheet opens on visionOS and macOS (no shake there) and a second
/// way in on an iPhone or iPad for people who will never think to shake one.
///
/// It is a LIBRARY TARGET and not an app, as in the sponsoredtokens SDK: it is compiled on every
/// build, for iOS, visionOS and macOS, so it cannot drift from the API, and it needs no bundle id or
/// signing to do that. To run it, make an app in Xcode, add this package, and use this as your own:
///
/// ```swift
/// @main struct MyApp: App {
///   init() { FeedbackSample.start() }
///   var body: some Scene {
///     WindowGroup { CartScreen() }
///     #if os(macOS)
///       .commands { OverblastFeedbackCommands() }      // Help > Report a Problem…
///     Settings { SettingsScreen() }
///     #endif
///   }
/// }
/// ```
public enum FeedbackSample {
  /// Call once at launch.
  @MainActor
  public static func start() {
    OverblastFeedback.start(
      key: "obfk_REPLACEWITHYOURKEY000000",       // the console's Feedback keys page
      options: FeedbackOptions(extra: ["plan": "pro"])   // shake is on where there is one (iPhone, iPad)
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
    #if os(macOS)
    list
    #else
    NavigationView { list }
    #endif
  }

  private var list: some View {
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
            // SwiftUI publishes little of its view hierarchy to point at; this makes the button
            // selectable by name in every report.
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
        // Button mode: the same call on every platform.
        OverblastFeedbackButton()
      }
    }
    .navigationTitle("Your cart")
  }
}

/// The primary pattern on visionOS and macOS: a row in the app's own Settings.
public struct SettingsScreen: View {
  public init() {}

  public var body: some View {
    Form {
      Section("Help") {
        OverblastFeedbackButton("Report a problem", systemImage: "exclamationmark.bubble")
        OverblastFeedbackButton("Suggest a feature", systemImage: "lightbulb", category: .idea)
      }
    }
  }
}
#endif
