#if canImport(UIKit)
import ObjectiveC
import SwiftUI
import UIKit

// What is never in a screenshot (contract §6): views the app marks private, every secure text field,
// and every field whose content type says it holds a card number, a password or a one-time code.
// They are painted over with solid boxes INSIDE the renderer, so the pixels underneath never exist
// in any image this library holds.

nonisolated(unsafe) private var overblastPrivateKey: UInt8 = 0

extension UIView {
  /// True blanks this view, and everything inside it, out of every screenshot, and keeps its text out
  /// of the selected element's label. Set it on a view that shows something the team should never
  /// see: a balance, a message thread, a medical record.
  ///
  /// The same effect without importing this module: an `accessibilityIdentifier` that starts with
  /// `overblast.private`.
  public var overblastPrivate: Bool {
    get { (objc_getAssociatedObject(self, &overblastPrivateKey) as? Bool) ?? false }
    set { objc_setAssociatedObject(self, &overblastPrivateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}

extension View {
  /// Blanks this view out of every feedback screenshot.
  ///
  /// It works by putting an invisible UIKit view behind this one (a `UIViewRepresentable` in a
  /// `.background`), sized to it and marked `overblastPrivate`. SwiftUI places that view in the
  /// window exactly where this one is drawn, scrolling included, so the screenshot masks the frame.
  /// It cannot mask what is drawn outside the view's own frame (a shadow, an overlay positioned with
  /// `offset`); mark the container instead.
  public func overblastPrivate() -> some View {
    background(OverblastPrivateMarker())
  }
}

extension View {
  /// Makes this view selectable by "Point at the problem", by name.
  ///
  /// SwiftUI draws most of a screen inside one hosting view, and publishes its elements only to an
  /// assistive technology (VoiceOver, Voice Control, Switch Control, UI tests). With none running, a
  /// tap on a SwiftUI screen can only name the hosting view. This puts an invisible UIKit view behind
  /// this one, carrying `id`, so the element picker finds it like any UIKit view: the element's `id`
  /// is `id`, its `type` is this view's own type (`Button`, `CartRow`), and its rectangle is this
  /// view's frame.
  /// `type` names what it is in the app's own words ("sticker"); without it, the marked view's
  /// own type is used, which for a view wrapped in a modifier (`.help(…)`) is the wrapper's.
  public func overblastElement(_ id: String, label: String? = nil, type: String? = nil) -> some View {
    background(OverblastElementMarker(id: id, label: label, type: type ?? NativeAnchorBuilder.cleanTypeName(String(describing: Self.self))))
  }
}

struct OverblastPrivateMarker: UIViewRepresentable {
  func makeUIView(context: Context) -> OverblastPrivateMarkerView {
    let view = OverblastPrivateMarkerView()
    view.overblastPrivate = true
    return view
  }

  func updateUIView(_ uiView: OverblastPrivateMarkerView, context: Context) {}
}

struct OverblastElementMarker: UIViewRepresentable {
  let id: String
  let label: String?
  let type: String

  func makeUIView(context: Context) -> OverblastElementMarkerView {
    OverblastElementMarkerView()
  }

  func updateUIView(_ uiView: OverblastElementMarkerView, context: Context) {
    uiView.elementId = id
    uiView.elementLabel = label
    uiView.elementType = type
  }
}

/// An invisible view this library puts behind a SwiftUI view to carry something about it. Never
/// what a person pointed at by itself; the picker reads what it carries instead.
class OverblastMarkerView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    isAccessibilityElement = false
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The marker behind `.overblastPrivate()`.
final class OverblastPrivateMarkerView: OverblastMarkerView {}

/// The marker behind `.overblastElement(_:)`.
final class OverblastElementMarkerView: OverblastMarkerView {
  var elementId = ""
  var elementLabel: String?
  var elementType = "View"
}

@MainActor
enum PrivacyMask {
  static let identifierPrefix = "overblast.private"

  /// The window-space rectangles to blank out of a screenshot of `window`.
  static func rects(in window: UIWindow) -> [CGRect] {
    var out: [CGRect] = []
    collect(window, window: window, into: &out)
    return out
  }

  private static func collect(_ view: UIView, window: UIWindow, into out: inout [CGRect]) {
    guard !view.isHidden, view.alpha > 0.01 else { return }
    if isPrivate(view) {
      out.append(view.convert(view.bounds, to: window))
      return
    }
    for sub in view.subviews { collect(sub, window: window, into: &out) }
  }

  static func isPrivate(_ view: UIView) -> Bool {
    if view.overblastPrivate { return true }
    if let id = view.accessibilityIdentifier, id.hasPrefix(identifierPrefix) { return true }
    if let field = view as? UITextField {
      if field.isSecureTextEntry { return true }
      if let type = field.textContentType, sensitiveContentTypes.contains(type) { return true }
    }
    if let text = view as? UITextView {
      if text.isSecureTextEntry { return true }
      if let type = text.textContentType, sensitiveContentTypes.contains(type) { return true }
    }
    return false
  }

  static let sensitiveContentTypes: Set<UITextContentType> = [
    .password, .newPassword, .oneTimeCode, .creditCardNumber,
  ]

  /// True when `view` or any ancestor is private: its text stays out of the element's label.
  static func isInsidePrivate(_ view: UIView) -> Bool {
    var v: UIView? = view
    while let current = v {
      if isPrivate(current) { return true }
      v = current.superview
    }
    return false
  }
}
#endif
