import CoreGraphics
import Foundation

/// Builds the `kind: "native"` element (contract §3.2) and holds it to the limits.
///
/// Platform-neutral on purpose: the UIKit half finds the view and its frame, and everything about
/// what may go on the wire is decided here, where it is tested on a Mac.
public enum NativeAnchorBuilder {
  /// An element for a frame in window points, inside a viewport of `viewport` points.
  public static func build(
    path: [String],
    type: String,
    id: String? = nil,
    label: String? = nil,
    frame: CGRect,
    viewport: CGSize
  ) -> FeedbackElement {
    let w = max(Double(viewport.width), 1)
    let h = max(Double(viewport.height), 1)
    let element = FeedbackElement(
      path: path,
      type: type,
      id: id,
      label: label,
      rect: FeedbackRect(
        x: Double(frame.minX) / w,
        y: Double(frame.minY) / h,
        w: Double(frame.width) / w,
        h: Double(frame.height) / h
      ),
      viewport: FeedbackElementViewport(w: Double(viewport.width), h: Double(viewport.height))
    )
    return clamp(element)
  }

  /// `element` within every limit: at most 12 path steps of at most 80 characters (the window and
  /// the 11 steps nearest the element are kept, because the middle of a deep hierarchy is the part a
  /// person reads least), type ≤ 80, id and label ≤ 120 or left out when empty, and a rectangle that
  /// lies inside 0...1 on both axes.
  public static func clamp(_ element: FeedbackElement) -> FeedbackElement {
    var e = element
    var steps = element.path
      .map { FeedbackText.truncate($0, FeedbackLimits.pathStep) }
      .filter { !$0.isEmpty }
    if steps.count > FeedbackLimits.pathSteps {
      steps = [steps[0]] + steps.suffix(FeedbackLimits.pathSteps - 1)
    }
    e.path = steps
    let type = FeedbackText.truncate(element.type, FeedbackLimits.elementType)
    e.type = type.isEmpty ? (steps.last ?? "UIView") : type
    // An id is matched against code; an ellipsis would make it a different id.
    e.id = FeedbackText.optional(element.id, FeedbackLimits.elementId, ellipsis: false)
    e.label = FeedbackText.optional(element.label, FeedbackLimits.elementLabel)
    e.rect = clampRect(element.rect)
    // The dom anchor's viewport rule (positive, at most 20000), which the native one shares.
    e.viewport = FeedbackElementViewport(w: viewportSide(element.viewport.w), h: viewportSide(element.viewport.h))
    return e
  }

  /// Each edge clamped into 0...1, so a view half off screen keeps its visible part.
  public static func clampRect(_ r: FeedbackRect) -> FeedbackRect {
    let x0 = unit(finite(r.x, 0))
    let y0 = unit(finite(r.y, 0))
    let x1 = unit(finite(r.x + r.w, 0))
    let y1 = unit(finite(r.y + r.h, 0))
    let rx = round4(x0), ry = round4(y0)
    return FeedbackRect(
      x: rx,
      y: ry,
      // Each value is checked on its own (0...1, as the worker's `checkRect` does); the sum stays
      // within 1 up to the last bit of a double.
      w: max(0, min(round4(round4(x1) - rx), 1 - rx)),
      h: max(0, min(round4(round4(y1) - ry), 1 - ry))
    )
  }

  /// A class name a person can read: no module prefix, no generic arguments. SwiftUI's hosts for a
  /// UIKit view (`PlatformViewHost<PlatformViewRepresentableAdaptor<MapView>>`) are named after the
  /// view they host, which is the part that means something to the app's developers.
  public static func cleanTypeName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let base: Substring
    var args: Substring = ""
    if let open = trimmed.firstIndex(of: "<") {
      base = trimmed[..<open]
      let close = trimmed.lastIndex(of: ">") ?? trimmed.endIndex
      args = trimmed.index(after: open) < close ? trimmed[trimmed.index(after: open)..<close] : ""
    } else {
      base = Substring(trimmed)
    }
    let name = base.split(separator: ".").last.map(String.init) ?? String(base)
    if wrapperHosts.contains(name), !args.isEmpty {
      let first = firstGenericArgument(args)
      let inner = cleanTypeName(first)
      if !inner.isEmpty { return inner }
    }
    return name
  }

  static let wrapperHosts: Set<String> = [
    "PlatformViewHost", "UIKitPlatformViewHost", "PlatformViewRepresentableAdaptor", "ViewControllerHost", "ModifiedContent",
  ]

  static func firstGenericArgument(_ args: Substring) -> String {
    var depth = 0
    for i in args.indices {
      switch args[i] {
      case "<": depth += 1
      case ">": depth -= 1
      case "," where depth == 0: return String(args[..<i])
      default: break
      }
    }
    return String(args)
  }

  private static func viewportSide(_ v: Double) -> Double { min(20_000, max(1, finite(v, 1))) }
  private static func unit(_ v: Double) -> Double { min(1, max(0, v)) }
  private static func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
  private static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
}
