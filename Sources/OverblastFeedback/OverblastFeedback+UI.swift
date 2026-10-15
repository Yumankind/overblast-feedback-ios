#if canImport(UIKit)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import UIKit

extension OverblastFeedback {
  /// Sets the library up and, on an iPhone or iPad unless `options.shakeToReport` is false, opens
  /// the report sheet when the device is shaken. Call it once, early
  /// (`application(_:didFinishLaunchingWithOptions:)` or your `App`'s `init`).
  ///
  /// On visionOS (and an iPhone app running on a Mac or on Apple Vision Pro) there is no shake to
  /// hear: nothing is installed, and the sheet opens from `present()`, typically behind a Settings
  /// button (`OverblastFeedbackButton`).
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
    SessionLifecycle.start(options: options)
    ErrorPromptUI.start()
  }

  /// Shake-to-report, switchable at run time. Setting it to true installs the shake hook if `start`
  /// did not. Always false where `isShakeAvailable` is false, and setting it there does nothing.
  @MainActor
  public static var isShakeEnabled: Bool {
    get {
      #if os(visionOS)
      return false
      #else
      return ShakeDetector.isEnabled
      #endif
    }
    set {
      #if !os(visionOS)
      guard isShakeAvailable else { return }
      ShakeDetector.isEnabled = newValue
      if newValue { ShakeDetector.install() }
      #endif
    }
  }

  /// Opens the report sheet, from a button, a menu item or a debug gesture of your own. Does nothing
  /// while a sheet is already open or before `start`. `trigger` is what the report says opened it:
  /// `.button` unless you say otherwise (`.shortcut` for a keyboard shortcut, `.agent` for an
  /// assistant).
  ///
  /// `category` nil opens on the key's default (its first category); one the key does not take is
  /// replaced by that default.
  ///
  /// `onResult` is called on the main actor once for every Send pressed in this sheet, with the
  /// receipt (`id`, `taskId`, `conversationId`, `known`) or the `FeedbackError` (its `code` is the
  /// service's refusal code), before `OverblastFeedback.onReportResult`. It is not called when the
  /// person cancels or swipes the sheet away, nor when the sheet does not open.
  @MainActor
  public static func present(
    category: FeedbackCategory? = nil,
    message: String = "",
    trigger: FeedbackTrigger = .button,
    onResult: (@MainActor (FeedbackResult) -> Void)? = nil
  ) {
    FeedbackPresenter.shared.present(category: category, message: message, trigger: trigger, onResult: onResult)
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
class FeedbackOverlayWindow: UIWindow {}

@MainActor
final class FeedbackPresenter {
  static let shared = FeedbackPresenter()

  private var overlay: FeedbackOverlayWindow?
  private weak var appWindow: UIWindow?

  var isPresenting: Bool { overlay != nil }

  func present(
    category: FeedbackCategory? = nil,
    message: String = "",
    trigger: FeedbackTrigger = .button,
    onResult: (@MainActor (FeedbackResult) -> Void)? = nil
  ) {
    guard overlay == nil, OverblastFeedback.isConfigured,
          let appWindow = ScreenContext.appWindow(), appWindow.windowScene != nil
    else { return }

    // Frozen BEFORE anything of ours is on screen.
    let capture = ScreenCapture.take(of: appWindow)
    guard let root = makeOverlay(over: appWindow) else { return }

    let sheet = FeedbackSheetController(capture: capture, appWindow: appWindow, category: category, message: message, trigger: trigger, onResult: onResult) { [weak self] in
      self?.dismiss()
    }
    let nav = UINavigationController(rootViewController: sheet)
    #if os(visionOS)
    // A form sheet is visionOS's own modal: a smaller glass panel in front of the window, which
    // stays visible behind it. visionOS has no detents and no grabber.
    nav.modalPresentationStyle = .formSheet
    nav.presentationController?.delegate = sheet
    #else
    // A native sheet that opens at half height and grows to full when the keyboard rises or the
    // content asks for the room (the sheet does that itself); always above the app's own UI, in the
    // scene the person is using.
    nav.modalPresentationStyle = .pageSheet
    nav.presentationController?.delegate = sheet
    if let sheetController = nav.sheetPresentationController {
      sheetController.detents = [.medium(), .large()]
      sheetController.selectedDetentIdentifier = .medium
      sheetController.prefersGrabberVisible = true
      sheetController.prefersScrollingExpandsWhenScrolledToEdge = true
      sheetController.prefersEdgeAttachedInCompactHeight = true
      sheetController.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheetController.preferredCornerRadius = max(16, ThemeUI.radius + 8)
    }
    #endif
    nav.view.tintColor = ThemeUI.accent(appWindow)
    root.present(nav, animated: true)
  }

  /// This library's own window above the app's, with a clear root to present from.
  private func makeOverlay(over appWindow: UIWindow) -> UIViewController? {
    guard let scene = appWindow.windowScene else { return nil }
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
    return root
  }

  /// "The app closed unexpectedly. Send a report?", once, from this library's own window. Send opens
  /// the sheet about the previous session; Not now forgets it.
  func offerCrashReport() {
    guard overlay == nil, OverblastFeedback.isConfigured, let appWindow = ScreenContext.appWindow(),
          let root = makeOverlay(over: appWindow)
    else { return }
    // An alert's width cannot be set, so the title is broken where its two lines come out even.
    let titleFont = UIFont.preferredFont(forTextStyle: .headline)
    let title = ThemeUI.singleLineWidth(Strings.crashOffer, font: titleFont) > 230
      ? BalancedWrap.twoLines(Strings.crashOffer) { ThemeUI.singleLineWidth($0, font: titleFont) }
      : Strings.crashOffer
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    alert.view.tintColor = ThemeUI.accent(appWindow)
    alert.addAction(UIAlertAction(title: Strings.crashOfferLater, style: .cancel) { [weak self] _ in
      OverblastFeedback.forgetPreviousSession()
      self?.tearDown()
    })
    alert.addAction(UIAlertAction(title: Strings.crashOfferSend, style: .default) { [weak self] _ in
      self?.tearDown()
      self?.present(category: .bug, message: "", trigger: .relaunch)
    })
    alert.preferredAction = alert.actions.last
    root.present(alert, animated: true)
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
/// The offer after an unexpected end, on iOS, iPadOS and visionOS.
@MainActor
enum CrashOffer {
  static func canShow() -> Bool {
    UIApplication.shared.applicationState == .active && ScreenContext.appWindow() != nil && !FeedbackPresenter.shared.isPresenting
  }

  static func show() { FeedbackPresenter.shared.offerCrashReport() }
}
#endif
