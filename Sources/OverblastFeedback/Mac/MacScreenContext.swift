#if os(macOS)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import AppKit

/// Which window the person is in, and what to call it.
@MainActor
enum ScreenContext {
  /// The app's key window, else its main window, else its frontmost ordinary window, else its
  /// frontmost window of any level that could take the keyboard; never one of this library's own.
  /// The key window can be the app's own sheet or panel, and then that is what the person is looking
  /// at.
  ///
  /// The last step is for a menu-bar app with no key window: its only window may be a popover, which
  /// is never main and sits above the normal level. `canBecomeKey` keeps out the status item's own
  /// window and other chrome the person cannot be working in.
  static func appWindow() -> NSWindow? {
    let app = NSApplication.shared
    if let key = usable(app.keyWindow) { return key }
    if let main = usable(app.mainWindow) { return main }
    return app.orderedWindows.first { usable($0) != nil && $0.level == .normal }
      ?? app.orderedWindows.first { usable($0) != nil && $0.canBecomeKey }
  }

  private static func usable(_ window: NSWindow?) -> NSWindow? {
    guard let window, !(window is FeedbackSheetWindow), window.isVisible, window.contentView != nil else { return nil }
    return window
  }

  /// The view controller showing: the content view controller, or the selected tab or last split
  /// item of one.
  static func topViewController(from root: NSViewController?) -> NSViewController? {
    var current = root
    var hops = 0
    while let vc = current, hops < 32 {
      hops += 1
      if let presented = vc.presentedViewControllers?.last {
        current = presented
      } else if let tab = vc as? NSTabViewController, tab.selectedTabViewItemIndex >= 0, tab.selectedTabViewItemIndex < tab.tabViewItems.count,
                let selected = tab.tabViewItems[tab.selectedTabViewItemIndex].viewController {
        current = selected
      } else if let split = vc as? NSSplitViewController, let last = split.splitViewItems.last(where: { !$0.isCollapsed })?.viewController {
        current = last
      } else {
        return vc
      }
    }
    return current
  }

  /// `screen` is the showing view controller's class, unless that is only SwiftUI's hosting
  /// controller (or there is none), when the window's title says more. `viewport` is the content
  /// size in points, with the backing scale factor as `dpr`.
  static func current(window: NSWindow? = nil) -> PlatformContext {
    guard let window = window ?? appWindow() else { return PlatformContext() }
    let title = window.title.isEmpty ? nil : window.title
    var screen: String?
    if let top = topViewController(from: window.contentViewController) {
      let isSwiftUI = String(reflecting: type(of: top)).hasPrefix("SwiftUI.")
      screen = isSwiftUI ? (title ?? NativeAnchorBuilder.cleanTypeName(String(describing: type(of: top)))) : NativeAnchorBuilder.cleanTypeName(String(describing: type(of: top)))
    } else {
      screen = title
    }
    let size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
    let scale = window.backingScaleFactor
    return PlatformContext(
      screen: screen,
      title: title,
      viewport: FeedbackViewport(w: Double(size.width), h: Double(size.height), dpr: scale > 0 ? Double(scale) : nil)
    )
  }
}
#endif
