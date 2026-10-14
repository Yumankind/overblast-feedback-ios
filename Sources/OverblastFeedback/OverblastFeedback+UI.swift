#if canImport(UIKit)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import UIKit

extension OverblastFeedback {
  /// Sets the library up and, unless `options.shakeToReport` is false, opens the report sheet when
  /// the device is shaken. Call it once, early (`application(_:didFinishLaunchingWithOptions:)` or
  /// your `App`'s `init`).
  ///
  /// - Parameters:
  ///   - key: the workspace's feedback key, `obfk_...`, from the console's Feedback keys page. It is
  ///     public by design: it can only file reports.
  ///   - endpoint: the ingest door. Leave it alone outside a test.
  ///   - reporter: who is using the app, if you know. `setReporter` changes it later.
  @MainActor
  public static func start(
    key: String,
    endpoint: URL = FeedbackClient.defaultEndpoint,
    reporter: FeedbackReporter? = nil,
    options: FeedbackOptions = FeedbackOptions()
  ) {
    configure(key: key, endpoint: endpoint, reporter: reporter, options: options)
    setPlatformContextProvider {
      await MainActor.run { ScreenContext.current() }
    }
    isShakeEnabled = options.shakeToReport
  }

  /// Shake-to-report, switchable at run time. Setting it to true installs the shake hook if `start`
  /// did not.
  @MainActor
  public static var isShakeEnabled: Bool {
    get { ShakeDetector.isEnabled }
    set {
      ShakeDetector.isEnabled = newValue
      if newValue { ShakeDetector.install() }
    }
  }

  /// Opens the report sheet, from a button, a menu item or a debug gesture of your own. Does nothing
  /// while a sheet is already open or before `start`.
  @MainActor
  public static func present(category: FeedbackCategory = .bug, message: String = "") {
    FeedbackPresenter.shared.present(category: category, message: message)
  }

  /// True while the report sheet is on screen.
  @MainActor
  public static var isPresenting: Bool { FeedbackPresenter.shared.isPresenting }

  /// A screenshot of the app's window as the report sheet would take it: private views and secure
  /// fields painted over, at most 2400 pixels on the long side, JPEG within 5 MB. With an element,
  /// its box is drawn on the image. For `report(...)` without the sheet; nil when there is no window.
  @MainActor
  public static func captureScreenshot(highlighting element: FeedbackElement? = nil) -> FeedbackScreenshot? {
    guard let window = ScreenContext.appWindow() else { return nil }
    return ScreenshotRenderer.screenshot(from: ScreenCapture.take(of: window), element: element)
  }

  /// The element under a point in the app window's coordinates, as the sheet's "Point at the
  /// problem" would find it.
  @MainActor
  public static func element(at point: CGPoint, in window: UIWindow? = nil) -> FeedbackElement? {
    guard let window = window ?? ScreenContext.appWindow() else { return nil }
    return ElementPicker.select(at: point, in: window, privateRects: PrivacyMask.rects(in: window))?.element
  }
}

/// This library's own window, above the app's, so the sheet never changes the app's view
/// controller hierarchy and the element picker can search that hierarchy as the person left it.
final class FeedbackOverlayWindow: UIWindow {}

@MainActor
final class FeedbackPresenter {
  static let shared = FeedbackPresenter()

  private var overlay: FeedbackOverlayWindow?
  private weak var appWindow: UIWindow?

  var isPresenting: Bool { overlay != nil }

  func present(category: FeedbackCategory = .bug, message: String = "") {
    guard overlay == nil, OverblastFeedback.isConfigured,
          let appWindow = ScreenContext.appWindow(), let scene = appWindow.windowScene
    else { return }

    // Frozen BEFORE anything of ours is on screen.
    let capture = ScreenCapture.take(of: appWindow)

    let window = FeedbackOverlayWindow(windowScene: scene)
    window.frame = appWindow.frame
    window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
    window.backgroundColor = .clear
    let root = UIViewController()
    root.view.backgroundColor = .clear
    window.rootViewController = root
    window.overrideUserInterfaceStyle = appWindow.overrideUserInterfaceStyle
    window.makeKeyAndVisible()
    overlay = window
    self.appWindow = appWindow

    let sheet = FeedbackSheetController(capture: capture, appWindow: appWindow, category: category, message: message) { [weak self] in
      self?.dismiss()
    }
    let nav = UINavigationController(rootViewController: sheet)
    nav.modalPresentationStyle = .pageSheet
    nav.presentationController?.delegate = sheet
    if let sheetController = nav.sheetPresentationController {
      sheetController.detents = [.large()]
      sheetController.prefersGrabberVisible = true
    }
    root.present(nav, animated: true)
  }

  func dismiss() {
    guard let overlay else { return }
    if let presented = overlay.rootViewController?.presentedViewController {
      presented.dismiss(animated: true) { [weak self] in self?.tearDown() }
    } else {
      tearDown()
    }
  }

  /// Called when the sheet is gone, by a button or by a swipe.
  func tearDown() {
    overlay?.isHidden = true
    overlay?.rootViewController = nil
    overlay = nil
    appWindow?.makeKey()
    appWindow = nil
  }
}
#endif
