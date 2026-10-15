#if canImport(UIKit) || os(macOS)
import SwiftUI

/// A button that opens the report sheet: button mode, the way in on visionOS and macOS, where there
/// is no shake, and a second way in on an iPhone or iPad for people who will never think to shake
/// one. It belongs in a Settings `Form`, a Help menu or a `List`, and looks like every other button
/// there.
///
/// ```swift
/// Form {
///   Section {
///     OverblastFeedbackButton()                                      // "Report a problem"
///     OverblastFeedbackButton("Suggest a feature", category: .idea)
///   }
/// }
/// ```
public struct OverblastFeedbackButton<Label: View>: View {
  private let category: FeedbackCategory
  private let message: String
  private let label: Label

  /// A button with a label of your own.
  public init(category: FeedbackCategory = .bug, message: String = "", @ViewBuilder label: () -> Label) {
    self.category = category
    self.message = message
    self.label = label()
  }

  public var body: some View {
    Button {
      OverblastFeedback.present(category: category, message: message)
    } label: {
      label
    }
  }
}

extension OverblastFeedbackButton where Label == Text {
  /// A text button, "Report a problem" unless you name it.
  public init(_ title: String = "Report a problem", category: FeedbackCategory = .bug, message: String = "") {
    self.init(category: category, message: message) { Text(title) }
  }
}

extension OverblastFeedbackButton where Label == SwiftUI.Label<Text, Image> {
  /// A button with an SF Symbol, as Settings rows usually have.
  public init(_ title: String = "Report a problem", systemImage: String, category: FeedbackCategory = .bug, message: String = "") {
    self.init(category: category, message: message) { SwiftUI.Label(title, systemImage: systemImage) }
  }
}
#endif

#if canImport(UIKit) || os(macOS)
/// "Report a Problem…" in the Help menu (macOS, and the iPad's menu bar). On a Mac this is the way
/// to report about the main window: a menu command leaves that window key, so it is the window the
/// sheet captures, where a button in a Settings window would capture the Settings window.
///
/// ```swift
/// WindowGroup { ContentView() }
///   .commands { OverblastFeedbackCommands() }
/// ```
public struct OverblastFeedbackCommands: Commands {
  private let title: String

  public init(_ title: String = "Report a Problem…") {
    self.title = title
  }

  public var body: some Commands {
    CommandGroup(after: .help) {
      OverblastFeedbackButton(title)
    }
  }
}
#endif
