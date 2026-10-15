#if canImport(UIKit) || os(macOS)
import OverblastFeedbackCore
import Foundation

/// Every sentence the sheet shows, in one place. English only for now; the worker's own refusal
/// sentences are shown as the worker wrote them.
enum Strings {
  static let title = "Send feedback"
  /// The sheet's title on a key that takes problem reports only.
  static let problemTitle = "Report a problem"

  static func title(for config: FeedbackEffectiveConfig) -> String {
    config.isProblemReportsOnly ? problemTitle : title
  }

  /// The categories the key takes, in its order, with their names.
  static func categories(for config: FeedbackEffectiveConfig) -> [(FeedbackCategory, String)] {
    config.categories.compactMap { c in categories.first { $0.0 == c } }
  }
  static let cancel = "Cancel"
  static let send = "Send"
  static let done = "Done"
  static let remove = "Remove"
  static let messagePlaceholder = "What happened? What did you expect?"
  static let messageLabel = "Message"
  static let category = "Category"
  static let categories: [(FeedbackCategory, String)] = [(.bug, "Bug"), (.idea, "Idea"), (.question, "Question"), (.other, "Other")]
  static let point = "Point at the problem"
  static let pointAgain = "Point somewhere else"
  static let clearSelection = "Clear"
  static let includeScreenshot = "Include screenshot"
  static let screenshotPreview = "Screenshot that will be sent"
  static let emailPlaceholder = "Email (optional)"
  static let emailFootnote = "Optional. The team may reply to this address."
  static let sending = "Sending…"
  static let sent = "Sent. Thank you."
  static let savedForLater = "Saved. It will be sent the next time the app opens."
  #if os(macOS)
  static let pointerHint = "Click the part that's wrong"
  static let pointerImage = "Frozen picture of the window"
  static let pointerImageHint = "Click the part of the window that is wrong."
  #else
  static let pointerHint = "Tap the part that's wrong"
  static let pointerImage = "Frozen screenshot"
  static let pointerImageHint = "Touch the part of the screen that is wrong."
  #endif
  static let reportProblem = "Report a problem"
  static let useThis = "Use this"
  static let change = "Change"
  static let pickRemoveHint = "Remove the selected part"
  static let pickChangeHint = "Point at a different part"
  static let editScreenshot = "Edit"
  static let editScreenshotHint = "Cover or blur parts before sending"
  static let editTitle = "Edit screenshot"
  static let editHint = "Drag over anything you'd rather not send. Cover hides it under a box; Blur smudges it."
  static let editMode = "Edit with"
  static let editCover = "Cover"
  static let editBlur = "Blur"
  static let editUndo = "Undo"
  static let editClear = "Clear"
  static let screenshotEdited = "Screenshot, edited"
  static let crashOffer = "The app closed unexpectedly. Send a report?"
  static let crashOfferSend = "Send report"
  static let crashOfferLater = "Not now"
  static let crashPlaceholder = "What were you doing when it closed?"
  static let promptText = "Something may have gone wrong. Tell us?"
  static let promptReport = "Report"
  static let promptClose = "Close"
  static let clearSelectionHint = "Clear the selected element"
  static let removeScreenshotHint = "Remove the screenshot"

  static func selected(_ element: FeedbackElement) -> String {
    if let label = element.label, !label.isEmpty { return "\(element.type) “\(label)”" }
    return element.type
  }

  /// "Will be sent: your message, the selected element, the screenshot, logs from this session and
  /// device details."
  static func willSend(element: Bool, screenshot: Bool, logs: Bool, email: Bool, crash: Bool = false) -> String {
    var parts = ["your message"]
    if element { parts.append("the selected element") }
    if screenshot { parts.append("the screenshot") }
    if crash { parts.append("how the app closed") }
    if logs { parts.append(crash ? "logs from before it closed" : "logs from this session") }
    if email { parts.append("your email address") }
    parts.append("device and app details")
    let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
    return "Will be sent: \(list)."
  }
}
#endif
