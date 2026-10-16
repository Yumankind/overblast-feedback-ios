#if os(macOS)
import AppKit

/// What the person pointed at, found in the LIVE view hierarchy of the window's content under a
/// point (content-view points from the top-left corner).
///
/// AppKit: the deepest visible view whose bounds hold the point, including views that take no
/// clicks, with an `NSControl` treated as one piece (a click on a button's title is a click on the
/// button, and a label is an `NSTextField`, which is a control too).
///
/// SwiftUI: under a hosting view the search tries, in order, an `.overblastElement(_:)` marker (the
/// integrator said what this is), then the accessibility element AppKit reports at that point
/// (`accessibilityHitTest`, which on a Mac answers whether or not VoiceOver is running), then the
/// hosting view itself with a 44-point square round the click.
@MainActor
enum ElementPicker {
  struct Selection {
    let element: FeedbackElement
    /// In content-view points from the top-left corner.
    let frame: CGRect
  }

  static func select(at point: CGPoint, in window: NSWindow, privateRects: [CGRect] = []) -> Selection? {
    guard let content = window.contentView else { return nil }
    let viewport = content.bounds.size
    guard CGRect(origin: .zero, size: viewport).contains(point) else { return nil }
    let native = MacGeometry.native(point, in: content)
    var view = deepestView(at: native, in: content, content: content) ?? content
    // 0. The app's own answer first (`OverblastFeedback.elementResolver`): something drawn on a
    // canvas has no view and no accessibility element, and only the app knows what is there.
    if let resolved = OverblastFeedback.elementResolver?(point, window) {
      let named = isSwiftUIHost(view) && !(view is NSControl) ? swiftUIRoot(of: view, content: content) : view
      let insidePrivate = PrivacyMask.isInsidePrivate(view) || privateRects.contains { $0.contains(point) }
      return selection(
        for: resolved, at: point, in: CGRect(origin: .zero, size: viewport),
        path: path(to: named, in: window, content: content), insidePrivate: insidePrivate, privateRects: privateRects
      )
    }
    // A control is found exactly even when SwiftUI made it (`TextField`, `Toggle` and `Picker` are
    // AppKit controls underneath). Any other view of SwiftUI's own (a focus ring, a drawing layer)
    // is part of the hosting view's picture, so the search starts from the hosting view.
    let isSwiftUI = isSwiftUIHost(view) && !(view is NSControl)
    if isSwiftUI {
      view = swiftUIRoot(of: view, content: content)
    } else if isSwiftUIHost(view), case let root = swiftUIRoot(of: view, content: content),
              let marked = markedElement(at: point, under: root, content: content) {
      // A SwiftUI control the integrator named with `.overblastElement(_:)`: the name they gave is
      // what the team searches for, so it wins over the control's own class
      // (`SwiftUIAppKitButton`), which is the same for every button in the app. The path is the
      // hosting view's, then the marked view's type, as for any other marked SwiftUI view.
      let steps = path(to: root, in: window, content: content) + [marked.type]
      let insidePrivate = PrivacyMask.isInsidePrivate(view) || privateRects.contains { $0.intersects(marked.frame) }
      let element = NativeAnchorBuilder.build(
        path: steps, type: marked.type, id: marked.id,
        label: insidePrivate ? nil : (marked.label ?? label(of: view)),
        frame: marked.frame, viewport: viewport
      )
      return Selection(element: element, frame: marked.frame)
    }
    let insidePrivate = PrivacyMask.isInsidePrivate(view) || privateRects.contains { $0.contains(point) }
    var steps = path(to: view, in: window, content: content)

    if isSwiftUI {
      let node = markedElement(at: point, under: view, content: content) ?? accessibilityElement(at: native, under: view, in: window, content: content)
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
      let spot = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44).intersection(CGRect(origin: .zero, size: viewport))
      let id = view.accessibilityIdentifier()
      let element = NativeAnchorBuilder.build(path: steps, type: typeName(view), id: id.isEmpty ? nil : id, frame: spot, viewport: viewport)
      return Selection(element: element, frame: spot)
    }

    let frame = MacGeometry.topLeftRect(of: view, in: content)
    let id = view.accessibilityIdentifier()
    let element = NativeAnchorBuilder.build(
      path: steps,
      type: typeName(view),
      id: id.isEmpty ? nil : id,
      label: insidePrivate ? nil : label(of: view),
      frame: frame,
      viewport: viewport
    )
    return Selection(element: element, frame: frame)
  }

  // MARK: AppKit

  /// `point` is in `content`'s own coordinates.
  /// The selection for an element the app named: its frame (or a 44-point square round the point
  /// when it gave none) kept inside the content view, the view path with the app's type at the end,
  /// and no label when any of it lies in a private area.
  static func selection(
    for resolved: OverblastFeedback.PointedElement, at point: CGPoint, in bounds: CGRect,
    path steps: [String], insidePrivate: Bool, privateRects: [CGRect]
  ) -> Selection {
    let spot = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44).intersection(bounds)
    let clipped = (resolved.frame.isEmpty ? spot : resolved.frame).intersection(bounds)
    let frame = clipped.isNull || clipped.isEmpty ? spot : clipped
    let element = NativeAnchorBuilder.build(
      path: steps + [resolved.type],
      type: resolved.type,
      id: resolved.id,
      label: insidePrivate || privateRects.contains(where: { $0.intersects(frame) }) ? nil : resolved.label,
      frame: frame,
      viewport: bounds.size
    )
    return Selection(element: element, frame: frame)
  }

  static func deepestView(at point: CGPoint, in root: NSView, content: NSView) -> NSView? {
    let local = root.convert(point, from: content)
    guard isVisible(root), root.bounds.contains(local) else { return nil }
    // A control is one piece, and found even when disabled ("this greyed-out button is wrong").
    if root is NSControl { return root }
    // A view that declines the click is a pass-through layer (a transparent overlay): what the
    // person sees is underneath. SwiftUI's hosting views are never treated so, because they answer
    // hit tests by their content's shape and a click on a `Text` is still a click on the screen.
    if root !== content, !isSwiftUIHost(root), let superview = root.superview,
       root.hitTest(superview.convert(point, from: content)) == nil {
      return nil
    }
    for sub in root.subviews.reversed() where !isMarkerOrMarkerHost(sub) {
      if let hit = deepestView(at: point, in: sub, content: content) { return hit }
    }
    return root
  }

  /// This library's invisible markers, and SwiftUI's host view around one (which exists only to
  /// carry it), are never what a person pointed at.
  static func isMarkerOrMarkerHost(_ view: NSView) -> Bool {
    if view is OverblastMarkerView { return true }
    return !view.subviews.isEmpty && view.subviews.allSatisfy { $0 is OverblastMarkerView }
  }

  /// The smallest `.overblastElement(_:)` marker under `view` whose frame holds the point.
  static func markedElement(at point: CGPoint, under view: NSView, content: NSView) -> Node? {
    var best: (marker: OverblastElementMarkerView, frame: CGRect)?
    func visit(_ v: NSView) {
      guard isVisible(v) else { return }
      if let marker = v as? OverblastElementMarkerView {
        let frame = MacGeometry.topLeftRect(of: marker, in: content)
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

  static func isVisible(_ view: NSView) -> Bool {
    !view.isHidden && view.alphaValue > 0.01
  }

  /// The window first, the element last, from the content view down. A view that is a view
  /// controller's root is named after the view controller; AppKit's private wrappers are left out.
  static func path(to view: NSView, in window: NSWindow, content: NSView) -> [String] {
    var chain: [NSView] = []
    var v: NSView? = view
    while let current = v {
      chain.append(current)
      if current === content { break }
      v = current.superview
    }
    var steps = [NativeAnchorBuilder.cleanTypeName(String(describing: type(of: window)))]
    for (index, v) in chain.reversed().enumerated() {
      let isTarget = index == chain.count - 1
      if let vc = v.nextResponder as? NSViewController, vc.isViewLoaded, vc.view === v {
        steps.append(NativeAnchorBuilder.cleanTypeName(String(describing: type(of: vc))))
        continue
      }
      let name = typeName(v)
      if !isTarget, noise(name) { continue }
      steps.append(name)
    }
    return steps
  }

  static func typeName(_ view: NSView) -> String {
    NativeAnchorBuilder.cleanTypeName(String(describing: type(of: view)))
  }

  static let noiseNames: Set<String> = ["NSClipView", "NSThemeFrame", "NSTitlebarContainerView"]

  static func noise(_ name: String) -> Bool {
    noiseNames.contains(name) || name.hasPrefix("_")
  }

  /// The view's accessible name, else its visible text. Never an editable field's content, only its
  /// placeholder: what a person typed is theirs.
  static func label(of view: NSView) -> String? {
    if view is NSSecureTextField { return nil }
    if let label = view.accessibilityLabel(), !label.isEmpty { return label }
    // A control's visible title, which is where SwiftUI's own buttons keep their text.
    if view is NSButton || view is NSPopUpButton, let title = view.accessibilityTitle(), !title.isEmpty { return title }
    switch view {
    case let p as NSPopUpButton: return p.titleOfSelectedItem
    case let b as NSButton: return b.title.isEmpty ? nil : b.title
    case let s as NSSegmentedControl:
      return s.selectedSegment >= 0 ? s.label(forSegment: s.selectedSegment) : nil
    case let f as NSTextField:
      return f.isEditable ? f.placeholderString : (f.stringValue.isEmpty ? nil : f.stringValue)
    default: return nil
    }
  }

  /// A view SwiftUI draws into. Not only classes in the SwiftUI module: the system wraps SwiftUI
  /// in hosting views of its own (iOS 26's floating toolbar is a `FloatingBarHostingView` that
  /// lives outside it), so the class chain is walked and any hosting view counts. Missing one
  /// meant its `.overblastElement` markers were never searched and the whole bar was named.
  static func isSwiftUIHost(_ view: NSView) -> Bool {
    var cls: AnyClass? = type(of: view)
    while let current = cls, current != NSView.self {
      let name = String(reflecting: current)
      if name.hasPrefix("SwiftUI.") || name.hasSuffix("HostingView") || name.contains("HostingView<") { return true }
      cls = class_getSuperclass(current)
    }
    return false
  }

  /// The outermost of the SwiftUI views that hold `view`: the hosting view, normally.
  static func swiftUIRoot(of view: NSView, content: NSView) -> NSView {
    var root = view
    var v = view.superview
    while let current = v, isSwiftUIHost(current) {
      root = current
      if current === content { break }
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

  /// The accessibility element AppKit reports under the point, when it is something smaller than
  /// the hosting view itself. `point` is in `content`'s own coordinates.
  static func accessibilityElement(at point: CGPoint, under view: NSView, in window: NSWindow, content: NSView) -> Node? {
    let inWindow = content.convert(point, to: nil)
    let onScreen = window.convertPoint(toScreen: inWindow)
    guard let hit = view.accessibilityHitTest(onScreen) as? NSAccessibilityProtocol else { return nil }
    if let hitView = hit as? NSView, hitView === view || hitView === content { return nil }
    let screenFrame = hit.accessibilityFrame()
    guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
    let windowFrame = window.convertFromScreen(screenFrame)
    let frame = MacGeometry.topLeft(content.convert(windowFrame, from: nil), in: content)
    guard frame.contains(MacGeometry.topLeftPoint(point, in: content)) else { return nil }
    let role: NSAccessibility.Role? = hit.accessibilityRole()
    guard let type = typeName(role: role) else { return nil }
    let id: String? = hit.accessibilityIdentifier()
    let label: String? = hit.accessibilityLabel()
    return Node(
      type: type,
      id: id.flatMap { $0.isEmpty ? nil : $0 },
      // The label only, never `accessibilityValue`: on a text field that is what the person typed.
      label: label,
      frame: frame
    )
  }

  /// A readable type for an accessibility role, or nil for a role that names a container rather than
  /// a thing a person points at.
  static func typeName(role: NSAccessibility.Role?) -> String? {
    guard let role else { return nil }
    switch role {
    case .button: return "Button"
    case .link: return "Link"
    case .textField, .textArea: return "TextField"
    case .checkBox: return "Toggle"
    case .radioButton: return "RadioButton"
    case .popUpButton, .menuButton: return "Picker"
    case .slider: return "Slider"
    case .image: return "Image"
    case .staticText: return "Text"
    case .group, .scrollArea, .splitGroup, .layoutArea, .unknown, .window, .application: return nil
    default:
      let raw = role.rawValue
      return raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
    }
  }
}

extension MacGeometry {
  /// The inverse of `native(_:in:)`: a point in `content`'s own coordinates, measured from its
  /// top-left corner.
  static func topLeftPoint(_ p: CGPoint, in content: NSView) -> CGPoint {
    let b = content.bounds
    return CGPoint(x: p.x - b.minX, y: content.isFlipped ? p.y - b.minY : b.maxY - p.y)
  }
}
#endif
