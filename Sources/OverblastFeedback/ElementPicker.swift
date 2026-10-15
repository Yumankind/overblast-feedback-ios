#if canImport(UIKit)
import UIKit

/// What the person pointed at, found in the LIVE view hierarchy under a point in window space.
///
/// UIKit: the deepest visible view whose bounds hold the point. Unlike `hitTest`, a view that takes
/// no touches (a `UILabel`, a `UIImageView`) can be found, because "this label is wrong" is the
/// commonest report there is. A `UIControl` is a leaf: a tap on a button's title is a tap on the
/// button.
///
/// SwiftUI: most of a SwiftUI screen is drawn by one hosting view and has no `UIView` of its own,
/// so under a hosting view the search continues through the accessibility elements SwiftUI publishes
/// for VoiceOver, and the smallest one whose frame holds the point wins. That is coarser than UIKit:
/// an element is what VoiceOver would focus (a `Button` with its label, a `Text`), its `type` comes
/// from its traits rather than from a view type, and anything hidden from accessibility cannot be
/// selected.
@MainActor
enum ElementPicker {
  struct Selection {
    let element: FeedbackElement
    /// In window points.
    let frame: CGRect
  }

  static func select(at point: CGPoint, in window: UIWindow, privateRects: [CGRect] = []) -> Selection? {
    guard window.bounds.contains(point) else { return nil }
    var view = deepestView(at: point, in: window) ?? window
    // A view of SwiftUI's own inside the hosting view (visionOS draws a `Button` in a
    // `_UIInheritedView`) is part of the hosting view's picture: the search below starts from the
    // outermost SwiftUI view, so a marker beside it is still found.
    if isSwiftUIHost(view) { view = swiftUIRoot(of: view) }
    let viewport = window.bounds.size
    let insidePrivate = PrivacyMask.isInsidePrivate(view) || privateRects.contains { $0.contains(point) }
    var steps = path(to: view, in: window)

    // Only when the view found is SwiftUI's own: a UIKit view hosted inside SwiftUI (a
    // `UIViewRepresentable`) is found exactly, like any other UIKit view.
    if isSwiftUIHost(view) {
      // 1. The accessibility tree, which SwiftUI publishes only while an assistive technology runs.
      // 2. An `.overblastElement(_:)` marker under the point.
      let node = accessibilityElement(at: point, under: view, in: window) ?? markedElement(at: point, under: view, in: window)
      if let node {
        steps.append(node.type)
        let element = NativeAnchorBuilder.build(
          path: steps,
          type: node.type,
          id: node.id,
          label: insidePrivate || privateRects.contains(where: { $0.intersects(node.frame) }) ? nil : node.label,
          frame: node.frame,
          viewport: viewport
        )
        return Selection(element: element, frame: node.frame)
      }
      // 3. Neither: all that can be named is the hosting view, so the rectangle says WHERE instead,
      // a 44-point square (the minimum touch target) round the tap.
      let spot = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44).intersection(window.bounds)
      let element = NativeAnchorBuilder.build(path: steps, type: typeName(view), id: view.accessibilityIdentifier, frame: spot, viewport: viewport)
      return Selection(element: element, frame: spot)
    }

    let frame = view.convert(view.bounds, to: window)
    let element = NativeAnchorBuilder.build(
      path: steps,
      type: typeName(view),
      id: view.accessibilityIdentifier,
      label: insidePrivate ? nil : label(of: view),
      frame: frame,
      viewport: viewport
    )
    return Selection(element: element, frame: frame)
  }

  // MARK: UIKit

  static func deepestView(at point: CGPoint, in root: UIView) -> UIView? {
    let local = root.convert(point, from: root.window ?? root)
    guard isVisible(root), root.bounds.contains(local) else { return nil }
    // A view that takes touches but declines this one is a pass-through layer (a transparent
    // overlay, a floating bar host the size of the screen): what the person sees is underneath.
    // A view that takes no touches at all (a label, an image) is still found by its bounds.
    // A control is one piece, and found even when disabled ("this greyed-out button is wrong").
    if root is UIControl { return root }
    if root.isUserInteractionEnabled, !(root is UIWindow), root.hitTest(local, with: nil) == nil { return nil }
    for sub in root.subviews.reversed() where !isMarkerOrMarkerHost(sub) {
      if let hit = deepestView(at: point, in: sub) { return hit }
    }
    return root
  }

  /// This library's invisible markers, and SwiftUI's host view around one (which exists only to
  /// carry it), are never what a person pointed at.
  static func isMarkerOrMarkerHost(_ view: UIView) -> Bool {
    if view is OverblastMarkerView { return true }
    return !view.subviews.isEmpty && view.subviews.allSatisfy { $0 is OverblastMarkerView }
  }

  /// The smallest `.overblastElement(_:)` marker under `view` whose frame holds the point.
  static func markedElement(at point: CGPoint, under view: UIView, in window: UIWindow) -> Node? {
    var best: (marker: OverblastElementMarkerView, frame: CGRect)?
    func visit(_ v: UIView) {
      guard isVisible(v) else { return }
      if let marker = v as? OverblastElementMarkerView {
        let frame = marker.convert(marker.bounds, to: window)
        if frame.contains(point), best.map({ frame.width * frame.height < $0.frame.width * $0.frame.height }) ?? true {
          best = (marker, frame)
        }
      }
      for sub in v.subviews { visit(sub) }
    }
    visit(view)
    guard let found = best else { return nil }
    return Node(type: found.marker.elementType, id: found.marker.elementId, label: found.marker.elementLabel, frame: found.frame)
  }

  static func isVisible(_ view: UIView) -> Bool {
    !view.isHidden && view.alpha > 0.01
  }

  static func ancestors(of view: UIView) -> [UIView] {
    var out: [UIView] = []
    var v = view.superview
    while let current = v {
      out.append(current)
      v = current.superview
    }
    return out
  }

  /// Window first, element last. A view that is a view controller's root is named after the view
  /// controller, which is the name in the app's source; UIKit's private wrappers are left out.
  static func path(to view: UIView, in window: UIWindow) -> [String] {
    var chain: [UIView] = [view]
    chain.append(contentsOf: ancestors(of: view))
    var steps: [String] = []
    for (index, v) in chain.reversed().enumerated() {
      let isTarget = index == chain.count - 1
      if let vc = v.next as? UIViewController, vc.viewIfLoaded === v {
        steps.append(NativeAnchorBuilder.cleanTypeName(String(describing: type(of: vc))))
        continue
      }
      let name = typeName(v)
      if !isTarget, v !== window, noise(name) { continue }
      steps.append(name)
    }
    return steps
  }

  static func typeName(_ view: UIView) -> String {
    NativeAnchorBuilder.cleanTypeName(String(describing: type(of: view)))
  }

  static let noiseNames: Set<String> = [
    "UITransitionView", "UIDropShadowView", "UILayoutContainerView", "UINavigationTransitionView",
    "UIViewControllerWrapperView", "UITableViewWrapperView", "UIParallaxDimmingView",
  ]

  static func noise(_ name: String) -> Bool {
    noiseNames.contains(name) || (name.hasPrefix("_") && name != "_UIHostingView")
  }

  /// The view's accessible name, else its visible text. Never a text field's content, only its
  /// placeholder: what a person typed is theirs.
  static func label(of view: UIView) -> String? {
    if let label = view.accessibilityLabel, !label.isEmpty { return label }
    switch view {
    case let l as UILabel: return l.text
    case let b as UIButton: return b.currentTitle ?? b.titleLabel?.text
    case let f as UITextField: return f.placeholder
    case let s as UISegmentedControl:
      return s.selectedSegmentIndex >= 0 ? s.titleForSegment(at: s.selectedSegmentIndex) : nil
    default: return nil
    }
  }

  static func isSwiftUIHost(_ view: UIView) -> Bool {
    String(reflecting: type(of: view)).hasPrefix("SwiftUI.")
  }

  /// The outermost of the SwiftUI views that hold `view`: the hosting view, normally.
  static func swiftUIRoot(of view: UIView) -> UIView {
    var root = view
    var v = view.superview
    while let current = v, isSwiftUIHost(current), !(current is UIWindow) {
      root = current
      v = current.superview
    }
    return root
  }

  // MARK: Accessibility (SwiftUI)

  struct Node {
    let type: String
    let id: String?
    let label: String?
    let frame: CGRect
  }

  /// The smallest accessibility element under `view` (or under the nearest SwiftUI host above it)
  /// whose frame holds the point.
  static func accessibilityElement(at point: CGPoint, under view: UIView, in window: UIWindow) -> Node? {
    let roots = [view] + ancestors(of: view).prefix { isSwiftUIHost($0) }
    var best: (object: NSObject, frame: CGRect)?
    var visited = 0
    func visit(_ object: NSObject, depth: Int) {
      guard depth < 40, visited < 4000 else { return }
      visited += 1
      if object.isAccessibilityElement {
        // `accessibilityFrame` is in screen coordinates; for a full-screen window that is the
        // window's own space, and the conversion covers a window that is not (Stage Manager, Split
        // View).
        let frame = windowFrame(ofScreenFrame: object.accessibilityFrame, in: window)
        if frame.contains(point), frame.width > 0, frame.height > 0 {
          if best == nil || frame.width * frame.height < best!.frame.width * best!.frame.height {
            best = (object, frame)
          }
        }
      }
      for child in children(of: object) { visit(child, depth: depth + 1) }
    }
    for root in roots {
      visit(root, depth: 0)
      if best != nil { break }
    }
    guard let found = best else { return nil }
    let id = (found.object as? UIAccessibilityIdentification)?.accessibilityIdentifier
    return Node(
      type: typeName(traits: found.object.accessibilityTraits),
      id: id.flatMap { $0.isEmpty ? nil : $0 },
      // The label only, never `accessibilityValue`: on a text field that is what the person typed.
      label: found.object.accessibilityLabel,
      frame: found.frame
    )
  }

  /// An `accessibilityFrame` (screen coordinates) in `window`'s own space.
  static func windowFrame(ofScreenFrame frame: CGRect, in window: UIWindow) -> CGRect {
    #if os(visionOS)
    // There is no `UIScreen` on visionOS. The accessibility frames are in the space
    // `UIAccessibility.convertToScreenCoordinates` maps to, so the window's own bounds mapped the same
    // way give the offset and the scale back.
    let windowInScreen = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window)
    guard windowInScreen.width > 0, windowInScreen.height > 0 else { return frame }
    let sx = window.bounds.width / windowInScreen.width
    let sy = window.bounds.height / windowInScreen.height
    return CGRect(
      x: (frame.minX - windowInScreen.minX) * sx,
      y: (frame.minY - windowInScreen.minY) * sy,
      width: frame.width * sx,
      height: frame.height * sy
    )
    #else
    return window.convert(frame, from: window.screen.coordinateSpace)
    #endif
  }

  static func children(of object: NSObject) -> [NSObject] {
    if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
      return elements
    }
    let count = object.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
    }
    if let view = object as? UIView {
      return view.subviews.filter { isVisible($0) && !isMarkerOrMarkerHost($0) }
    }
    return []
  }

  static func typeName(traits: UIAccessibilityTraits) -> String {
    if traits.contains(.button) { return "Button" }
    if traits.contains(.link) { return "Link" }
    if traits.contains(.searchField) { return "SearchField" }
    if traits.contains(.adjustable) { return "Adjustable" }
    if traits.contains(.image) { return "Image" }
    if traits.contains(.header) { return "Header" }
    if traits.contains(.tabBar) { return "TabBar" }
    if traits.contains(.staticText) { return "Text" }
    return "AccessibilityElement"
  }
}
#endif
