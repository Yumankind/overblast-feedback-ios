#if canImport(UIKit) && !os(visionOS)
import ObjectiveC
import UIKit

/// Shake-to-report without asking the app to subclass anything. Not compiled for visionOS, which
/// delivers no motion events to an app; `start` installs it only where `DeviceInfo.deliversShake`.
///
/// HOW: `-[UIWindow motionEnded:withEvent:]` is replaced, once, by an implementation that calls the
/// original first and then opens the sheet on a shake. UIWindow normally inherits that method from
/// UIResponder, so the method is first ADDED to UIWindow with the inherited implementation; only
/// UIWindow's own entry is then replaced, and every other responder in the app keeps UIResponder's
/// untouched. The original is always called first, so an app that handles shakes itself still sees
/// every one.
///
/// WHAT IT CANNOT SEE: a shake reaches the window by travelling up the responder chain from the first
/// responder. A view or view controller that overrides `motionEnded` and does not call `super`
/// swallows it, and then the sheet does not open. `OverblastFeedback.present()` is the way in for
/// such an app, from a button or a menu item.
///
/// It is installed by `start` when `shakeToReport` is on, or the first time `isShakeEnabled` is set
/// to true. It is never uninstalled; turning shake off only makes the replacement do nothing beyond
/// calling the original.
@MainActor
enum ShakeDetector {
  static var isEnabled = false
  private static var installed = false
  private static var lastShake = Date.distantPast
  /// Two shakes within this window are one shake. A vigorous shake reports `motionEnded` more than
  /// once, and a sheet that opens twice is a bug report about the bug reporter.
  static let debounce: TimeInterval = 1.5

  static func install() {
    guard !installed else { return }
    installed = true

    let selector = #selector(UIResponder.motionEnded(_:with:))
    guard let inherited = class_getInstanceMethod(UIWindow.self, selector) else { return }
    // A no-op when UIWindow already has its own entry; otherwise gives it one, so that the
    // replacement below is UIWindow's alone.
    class_addMethod(UIWindow.self, selector, method_getImplementation(inherited), method_getTypeEncoding(inherited))
    guard let own = class_getInstanceMethod(UIWindow.self, selector) else { return }

    typealias Original = @convention(c) (UIWindow, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
    let original = unsafeBitCast(method_getImplementation(own), to: Original.self)
    let replacement: @convention(block) (UIWindow, UIEvent.EventSubtype, UIEvent?) -> Void = { window, motion, event in
      original(window, selector, motion, event)
      if motion == .motionShake {
        MainActor.assumeIsolated { ShakeDetector.didShake(in: window) }
      }
    }
    method_setImplementation(own, imp_implementationWithBlock(replacement))
  }

  static func didShake(in window: UIWindow) {
    guard isEnabled, OverblastFeedback.isConfigured, !(window is FeedbackOverlayWindow) else { return }
    let now = Date()
    guard now.timeIntervalSince(lastShake) > debounce else { return }
    lastShake = now
    FeedbackPresenter.shared.present(trigger: .shake)
  }
}
#endif
