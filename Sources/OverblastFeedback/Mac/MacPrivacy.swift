#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI

// The Mac half of contract §6, the same rules as on iOS: views the app marks private, every secure
// text field, and every field whose content type says it holds a password or a one-time code are
// painted over with solid boxes INSIDE the renderer, so the pixels underneath never exist in any
// image this library holds.

nonisolated(unsafe) private var overblastPrivateKey: UInt8 = 0

extension NSView {
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
  /// It puts an invisible AppKit view behind this one (an `NSViewRepresentable` in a `.background`),
  /// sized to it and marked `overblastPrivate`. SwiftUI places that view in the window exactly where
  /// this one is drawn, scrolling included, so the screenshot masks the frame. It cannot mask what is
  /// drawn outside the view's own frame (a shadow, an overlay positioned with `offset`); mark the
  /// container instead.
  public func overblastPrivate() -> some View {
    background(OverblastPrivateMarker())
  }

  /// Makes this view selectable by "Point at the problem", by name: the element's `id` is `id`, its
  /// `type` is this view's own type (`Button`, `CartRow`), and its rectangle is this view's frame.
  public func overblastElement(_ id: String, label: String? = nil) -> some View {
    background(OverblastElementMarker(id: id, label: label, type: NativeAnchorBuilder.cleanTypeName(String(describing: Self.self))))
  }
}

struct OverblastPrivateMarker: NSViewRepresentable {
  func makeNSView(context: Context) -> OverblastPrivateMarkerView {
    let view = OverblastPrivateMarkerView()
    view.overblastPrivate = true
    return view
  }

  func updateNSView(_ nsView: OverblastPrivateMarkerView, context: Context) {}
}

struct OverblastElementMarker: NSViewRepresentable {
  let id: String
  let label: String?
  let type: String

  func makeNSView(context: Context) -> OverblastElementMarkerView {
    OverblastElementMarkerView()
  }

  func updateNSView(_ nsView: OverblastElementMarkerView, context: Context) {
    nsView.elementId = id
    nsView.elementLabel = label
    nsView.elementType = type
  }
}

/// An invisible view this library puts behind a SwiftUI view to carry something about it. It draws
/// nothing, takes no clicks and is hidden from accessibility; the picker reads what it carries.
class OverblastMarkerView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func accessibilityChildren() -> [Any]? { nil }
  override func isAccessibilityElement() -> Bool { false }
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

  /// The rectangles to blank out of a screenshot of `window`'s content, in content-view points from
  /// the top-left corner.
  static func rects(in window: NSWindow) -> [CGRect] {
    guard let content = window.contentView else { return [] }
    var out: [CGRect] = []
    collect(content, content: content, into: &out)
    return out
  }

  private static func collect(_ view: NSView, content: NSView, into out: inout [CGRect]) {
    guard !view.isHidden, view.alphaValue > 0.01 else { return }
    if isPrivate(view) {
      out.append(MacGeometry.topLeftRect(of: view, in: content))
      return
    }
    for sub in view.subviews { collect(sub, content: content, into: &out) }
  }

  static func isPrivate(_ view: NSView) -> Bool {
    if view.overblastPrivate { return true }
    if view.accessibilityIdentifier().hasPrefix(identifierPrefix) { return true }
    // SwiftUI's `SecureField` is an `NSSecureTextField` underneath.
    if view is NSSecureTextField { return true }
    if let field = view as? NSTextField, let type = field.contentType, isSensitive(type) { return true }
    return false
  }

  static func isSensitive(_ type: NSTextContentType) -> Bool {
    if type == .password || type == .oneTimeCode { return true }
    if #available(macOS 14.0, *) {
      if type == .newPassword || type == .creditCardNumber || type == .creditCardSecurityCode { return true }
    }
    return false
  }

  /// True when `view` or any ancestor is private: its text stays out of the element's label.
  static func isInsidePrivate(_ view: NSView) -> Bool {
    var v: NSView? = view
    while let current = v {
      if isPrivate(current) { return true }
      v = current.superview
    }
    return false
  }
}

/// AppKit's views are measured from the bottom-left corner unless they are flipped; the contract's
/// rectangles, the screenshot and the iOS half all measure from the top-left. Everything this half
/// hands around is in the window content view's points, from its top-left corner.
@MainActor
enum MacGeometry {
  static func topLeftRect(of view: NSView, in content: NSView) -> CGRect {
    topLeft(view.convert(view.bounds, to: content), in: content)
  }

  /// A rectangle in `content`'s own coordinates, measured from its top-left corner.
  static func topLeft(_ r: CGRect, in content: NSView) -> CGRect {
    let b = content.bounds
    let y = content.isFlipped ? r.minY - b.minY : b.maxY - r.maxY
    return CGRect(x: r.minX - b.minX, y: y, width: r.width, height: r.height)
  }

  /// A point measured from `content`'s top-left corner, in `content`'s own coordinates.
  static func native(_ p: CGPoint, in content: NSView) -> CGPoint {
    let b = content.bounds
    return CGPoint(x: b.minX + p.x, y: content.isFlipped ? b.minY + p.y : b.maxY - p.y)
  }
}
#endif
