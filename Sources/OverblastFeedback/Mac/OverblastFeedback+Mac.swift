#if os(macOS)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import AppKit
import SwiftUI

// The Mac half: the same calls as on iOS, so one integration compiles for both. There is no shake on
// a Mac; the sheet opens from `present()`, behind a Settings button (`OverblastFeedbackButton`) or a
// Help menu item.
extension OverblastFeedback {
  /// Sets the library up and tells it which window the person is in. Call it once, early (your
  /// `App`'s `init`, or `applicationDidFinishLaunching(_:)`). Nothing is installed in the app: the
  /// report sheet opens only from `present()`.
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
    SessionLifecycle.start(options: options)
    ErrorPromptUI.start()
  }

  /// Always false on a Mac, which delivers no shake; setting it does nothing. It is here so the same
  /// code compiles for iOS and macOS.
  @MainActor
  public static var isShakeEnabled: Bool {
    get { false }
    set {}
  }

  /// Opens the report sheet on the key window (the window the person is using), from a button, a
  /// menu item or a shortcut of your own. Does nothing while a sheet is already open, before `start`,
  /// or when the app has no window.
  ///
  /// The window's content is captured before the sheet appears, so a button in a Settings window
  /// reports the Settings window; to report about the main window, open it from a menu command
  /// (Help > Report a Problem), which leaves the main window key.
  ///
  /// `trigger` is what the report says opened it: `.button` unless you say otherwise (`.shortcut`
  /// for a keyboard shortcut, `.agent` for an assistant).
  @MainActor
  ///
  /// `category` nil opens on the key's default (its first category); one the key does not take is
  /// replaced by that default.
  public static func present(category: FeedbackCategory? = nil, message: String = "", trigger: FeedbackTrigger = .button) {
    FeedbackPresenter.shared.present(category: category, message: message, trigger: trigger)
  }

  /// True while the report sheet is on screen.
  @MainActor
  public static var isPresenting: Bool { FeedbackPresenter.shared.isPresenting }

  /// A picture of the key window's content as the report sheet would take it: private views and
  /// secure fields painted over, at most 2400 pixels on the long side, JPEG within 5 MB. With an
  /// element, its box is drawn on the image. For `report(...)` without the sheet; nil when there is no
  /// window.
  @MainActor
  public static func captureScreenshot(highlighting element: FeedbackElement? = nil, in window: NSWindow? = nil) -> FeedbackScreenshot? {
    guard let window = window ?? ScreenContext.appWindow(), let capture = ScreenCapture.take(of: window) else { return nil }
    return ScreenshotRenderer.screenshot(from: capture, element: element)
  }

  /// The element under a point in the window's content, in points measured from the content's
  /// top-left corner (the contract's orientation, not AppKit's), as "Point at the problem" would
  /// find it.
  @MainActor
  public static func element(at point: CGPoint, in window: NSWindow? = nil) -> FeedbackElement? {
    guard let window = window ?? ScreenContext.appWindow() else { return nil }
    return ElementPicker.select(at: point, in: window, privateRects: PrivacyMask.rects(in: window))?.element
  }
}

/// Swaps the report sheet and the pointer sheet on the app's window. The app's own windows and view
/// controllers are never changed; a sheet is a window of its own.
@MainActor
final class FeedbackPresenter {
  static let shared = FeedbackPresenter()

  private(set) var model: FeedbackSheetModel?
  private weak var appWindow: NSWindow?
  private var sheet: FeedbackSheetWindow?

  var isPresenting: Bool { model != nil }

  func present(category: FeedbackCategory? = nil, message: String = "", trigger: FeedbackTrigger = .button, in window: NSWindow? = nil) {
    guard model == nil, OverblastFeedback.isConfigured, let appWindow = window ?? ScreenContext.appWindow(),
          // Frozen BEFORE anything of ours is on screen.
          let capture = ScreenCapture.take(of: appWindow)
    else { return }
    let model = FeedbackSheetModel(capture: capture, category: category, message: message, trigger: trigger)
    model.onPoint = { [weak self] in self?.showPointer() }
    model.onFinish = { [weak self] in self?.dismiss() }
    self.model = model
    self.appWindow = appWindow
    begin(FeedbackSheetView(model: model))
  }

  func dismiss() {
    end()
    model = nil
    appWindow = nil
  }

  private func showPointer() {
    guard let model, let appWindow else { return }
    let pointer = PointerModel(capture: model.capture, appWindow: appWindow, selection: model.selection)
    pointer.onFinish = { [weak self] keep, selection in
      guard let self, let model = self.model else { return }
      if keep { model.selection = selection }
      self.end()
      self.begin(FeedbackSheetView(model: model))
    }
    let scale = PointerModel.displayScale(
      content: model.capture.windowSize,
      window: appWindow.contentLayoutRect.size,
      screen: appWindow.screen?.visibleFrame.size
    )
    end()
    begin(PointerView(model: pointer, scale: scale))
  }

  private func begin(_ root: some View) {
    guard let appWindow else { return }
    let host = NSHostingController(rootView: root)
    host.sizingOptions = [.preferredContentSize]
    let window = FeedbackSheetWindow(contentViewController: host)
    window.styleMask = [.titled]
    window.isReleasedWhenClosed = false
    window.appearance = appWindow.appearance
    sheet = window
    appWindow.beginSheet(window)
  }

  private func end() {
    guard let sheet else { return }
    if let parent = sheet.sheetParent {
      parent.endSheet(sheet)
    } else {
      sheet.orderOut(nil)
    }
    self.sheet = nil
  }
}
/// The offer after an unexpected end, on macOS: an alert sheet on the app's window, once.
@MainActor
enum CrashOffer {
  private static var showing = false

  static func canShow() -> Bool {
    !showing && NSApplication.shared.isActive && ScreenContext.appWindow() != nil && !FeedbackPresenter.shared.isPresenting
  }

  static func show() {
    guard let window = ScreenContext.appWindow(), window.attachedSheet == nil else { return }
    showing = true
    let alert = NSAlert()
    alert.messageText = Strings.crashOffer
    alert.alertStyle = .informational
    alert.addButton(withTitle: Strings.crashOfferSend)
    alert.addButton(withTitle: Strings.crashOfferLater)
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        showing = false
        if response == .alertFirstButtonReturn {
          // After the alert's own sheet has gone, so the capture is of the window, not of the alert.
          Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            FeedbackPresenter.shared.present(category: .bug, message: "", trigger: .relaunch, in: window)
          }
        } else {
          OverblastFeedback.forgetPreviousSession()
        }
      }
    }
  }
}
#endif
