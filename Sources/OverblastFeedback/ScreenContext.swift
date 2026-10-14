#if canImport(UIKit)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import UIKit

/// Which window and which screen the person is on.
@MainActor
enum ScreenContext {
  /// The app's key window in its foreground scene, never one of this library's own.
  static func appWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
    for scene in ordered {
      let windows = scene.windows.filter { !($0 is FeedbackOverlayWindow) && !$0.isHidden }
      if let key = windows.first(where: \.isKeyWindow) { return key }
      if let normal = windows.first(where: { $0.windowLevel == .normal }) { return normal }
    }
    return nil
  }

  /// The view controller on top: presented over everything, else the visible child of a navigation,
  /// tab or split controller.
  static func topViewController(from root: UIViewController?) -> UIViewController? {
    var current = root
    var hops = 0
    while let vc = current, hops < 32 {
      hops += 1
      if let presented = vc.presentedViewController, !presented.isBeingDismissed {
        current = presented
      } else if let nav = vc as? UINavigationController, let visible = nav.visibleViewController ?? nav.topViewController {
        current = visible
      } else if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
        current = selected
      } else if let split = vc as? UISplitViewController, let last = split.viewControllers.last {
        current = last
      } else if let child = vc.children.last(where: { $0.viewIfLoaded?.window != nil && !($0.viewIfLoaded?.isHidden ?? true) }) {
        // Any other container, the visible child. SwiftUI's `NavigationView` is a UIKit navigation controller
        // held as a child of the hosting controller.
        current = child
      } else {
        return vc
      }
    }
    return current
  }

  static func current(window: UIWindow? = nil) -> PlatformContext {
    guard let window = window ?? appWindow() else { return PlatformContext() }
    let top = topViewController(from: window.rootViewController)
    let screen = top.map { NativeAnchorBuilder.cleanTypeName(String(describing: type(of: $0))) }
    let title = top.flatMap { $0.navigationItem.title ?? $0.title }
    let scale = window.traitCollection.displayScale
    return PlatformContext(
      screen: screen,
      title: title,
      viewport: FeedbackViewport(w: Double(window.bounds.width), h: Double(window.bounds.height), dpr: scale > 0 ? Double(scale) : nil)
    )
  }
}
#endif
