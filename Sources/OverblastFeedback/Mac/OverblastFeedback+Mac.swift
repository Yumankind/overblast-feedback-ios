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

/// How much room there is for the report UI on the app's window, and whether a window-attached sheet
/// fits at all. Pure, so the arithmetic is tested.
///
/// A sheet hangs from the top of the window's content and AppKit lets it run past the window's
/// bottom and off the screen; the sheet is held to the content's height (and the screen's visible
/// part below the content's top), less a margin. Below `minUsable` a sheet would be too cramped to
/// use, and the report opens in a resizable panel of its own instead.
enum SheetSpace {
  static let margin: CGFloat = 24
  static let minUsable: CGFloat = 420
  static let maxPanelHeight: CGFloat = 720

  /// `content` is the parent's content rectangle in screen coordinates; `visible` the screen's
  /// visible frame (without the menu bar and the Dock).
  static func available(content: CGRect, visible: CGRect?) -> CGFloat {
    var h = content.height
    if let visible { h = min(h, content.maxY - visible.minY, visible.height) }
    return max(0, h - margin)
  }

  static func usesPanel(available: CGFloat) -> Bool { available < minUsable }

  /// A panel's height on a screen: as tall as the form wants, never taller than the screen allows.
  static func panelHeight(visible: CGRect) -> CGFloat {
    max(240, min(maxPanelHeight, visible.height - 2 * margin))
  }
}

/// Shows the report form, the pointer and the editor on the app's window: as sheets attached to it,
/// or, when the window is too short for a usable sheet, in one resizable panel. The app's own windows
/// and view controllers are never changed.
@MainActor
final class FeedbackPresenter {
  static let shared = FeedbackPresenter()

  private(set) var model: FeedbackSheetModel?
  private weak var appWindow: NSWindow?
  private var sheet: FeedbackSheetWindow?
  /// The panel, when the window is too short for a sheet.
  private var panel: FeedbackSheetWindow?
  private var panelDelegate: PanelDelegate?
  private var observers: [NSObjectProtocol] = []

  var isPresenting: Bool { model != nil }
  /// True when the report opened in a panel rather than as a sheet.
  var usesPanel: Bool { panel != nil }

  func present(category: FeedbackCategory? = nil, message: String = "", trigger: FeedbackTrigger = .button, in window: NSWindow? = nil) {
    guard model == nil, OverblastFeedback.isConfigured, let appWindow = window ?? ScreenContext.appWindow(),
          // Frozen BEFORE anything of ours is on screen.
          let capture = ScreenCapture.take(of: appWindow)
    else { return }
    let model = FeedbackSheetModel(capture: capture, category: category, message: message, trigger: trigger)
    model.onPoint = { [weak self] in self?.showPointer() }
    model.onEdit = { [weak self] in self?.showEditor() }
    model.onFinish = { [weak self] in self?.dismiss() }
    self.model = model
    self.appWindow = appWindow

    let available = space(of: appWindow)
    if SheetSpace.usesPanel(available: available) {
      openPanel(over: appWindow)
    } else {
      model.maxHeight = available
    }
    // The room is measured again whenever the window (or the panel) changes size.
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: appWindow, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.windowResized() }
    })
    begin(FeedbackSheetView(model: model))
  }

  private func space(of window: NSWindow) -> CGFloat {
    let content = window.convertToScreen(window.contentLayoutRect)
    return SheetSpace.available(content: content, visible: window.screen?.visibleFrame)
  }

  private func windowResized() {
    guard let model, let appWindow, panel == nil else { return }
    model.maxHeight = max(200, space(of: appWindow))
  }

  private func panelResized() {
    guard let model, let panel else { return }
    model.maxHeight = panel.contentLayoutRect.height
  }

  private func openPanel(over appWindow: NSWindow) {
    guard let model else { return }
    let visible = appWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    let height = SheetSpace.panelHeight(visible: visible)
    let panel = FeedbackSheetWindow(
      contentRect: CGRect(x: 0, y: 0, width: 480, height: height),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false
    )
    panel.title = model.title
    panel.isReleasedWhenClosed = false
    panel.appearance = appWindow.appearance
    panel.minSize = NSSize(width: 420, height: 240)
    panel.maxSize = NSSize(width: 900, height: visible.height)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    let delegate = PanelDelegate { [weak self] in self?.model?.cancel() }
    panel.delegate = delegate
    panelDelegate = delegate
    // Centred on the app's window, then pulled inside the screen's visible part.
    var frame = panel.frame
    frame.origin.x = appWindow.frame.midX - frame.width / 2
    frame.origin.y = appWindow.frame.midY - frame.height / 2
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    panel.setFrame(frame, display: false)
    model.maxHeight = panel.contentLayoutRect.height
    model.fillsHeight = true
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.panelResized() }
    })
    self.panel = panel
  }

  func dismiss() {
    end()
    panel?.orderOut(nil)
    panel = nil
    panelDelegate = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
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
    // The picture is scaled to fit the room there is: under the window's content in a sheet, the
    // screen's visible part in a panel.
    let room: CGSize
    if let panel {
      room = panel.screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    } else {
      room = CGSize(width: appWindow.contentLayoutRect.width, height: space(of: appWindow) + SheetSpace.margin)
    }
    let scale = PointerModel.displayScale(content: model.capture.windowSize, window: room, screen: panel == nil ? appWindow.screen?.visibleFrame.size : nil)
    end()
    begin(PointerView(model: pointer, scale: scale))
  }

  /// The screenshot editor, in the form's place; Done or Cancel brings the form back.
  private func showEditor() {
    guard let model, let appWindow else { return }
    let editor = ScreenshotEditorModel(original: model.capture.image, pointSize: model.capture.windowSize, masks: model.capture.privateRects, edits: model.edits)
    editor.onFinish = { [weak self] result in
      guard let self, let model = self.model else { return }
      if let result { model.edits = result }
      self.end()
      self.begin(FeedbackSheetView(model: model))
    }
    let height = panel.map { $0.contentLayoutRect.height } ?? min(560, space(of: appWindow))
    let width = min(640, max(480, appWindow.contentLayoutRect.width - 40))
    end()
    begin(ScreenshotEditorView(model: editor).frame(width: width, height: max(320, height)))
  }

  private func begin(_ root: some View) {
    guard let appWindow else { return }
    let host = NSHostingController(rootView: root)
    if let panel {
      // In the panel the content is swapped; the form fills the panel, the pointer and the editor
      // size it to themselves (inside the screen).
      let isForm = root is FeedbackSheetView
      host.sizingOptions = []
      panel.contentViewController = host
      if !isForm {
        // What the pointer or the editor asks for, inside the screen. (`fittingSize` is not
        // computed for a hosting view that is not sizing itself, so the view is asked directly.)
        let visible = panel.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let fitting = host.sizeThatFits(in: CGSize(width: visible.width - 40, height: visible.height - 40))
        panel.setContentSize(NSSize(width: max(420, min(fitting.width, visible.width - 40)), height: min(fitting.height, visible.height - 40)))
      } else if let model {
        panel.setContentSize(NSSize(width: max(480, panel.contentLayoutRect.width), height: SheetSpace.panelHeight(visible: panel.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800))))
        model.maxHeight = panel.contentLayoutRect.height
      }
      if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
      return
    }
    host.sizingOptions = [.preferredContentSize]
    let window = FeedbackSheetWindow(contentViewController: host)
    window.styleMask = [.titled]
    window.hidesOnDeactivate = false
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

/// The panel's close button is Cancel.
private final class PanelDelegate: NSObject, NSWindowDelegate {
  let onClose: @MainActor () -> Void
  init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    MainActor.assumeIsolated { onClose() }
    return false
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
    // An alert's width cannot be set, so the title is broken where its two lines come out even.
    let bold = NSFont.boldSystemFont(ofSize: 13)
    alert.messageText = BalancedWrap.twoLines(Strings.crashOffer) { ($0 as NSString).size(withAttributes: [.font: bold]).width }
    alert.alertStyle = .informational
    alert.addButton(withTitle: Strings.crashOfferSend)
    alert.addButton(withTitle: Strings.crashOfferLater)
    // A window too short for the alert sheet gets the alert as a window of its own.
    let room = SheetSpace.available(content: window.convertToScreen(window.contentLayoutRect), visible: window.screen?.visibleFrame)
    if room < 200 {
      let response = alert.runModal()
      showing = false
      answer(response, window: window)
      return
    }
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        showing = false
        answer(response, window: window)
      }
    }
  }

  private static func answer(_ response: NSApplication.ModalResponse, window: NSWindow) {
    if response == .alertFirstButtonReturn {
      // After the alert has gone, so the capture is of the window, not of the alert.
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 400_000_000)
        FeedbackPresenter.shared.present(category: .bug, message: "", trigger: .relaunch, in: window)
      }
    } else {
      OverblastFeedback.forgetPreviousSession()
    }
  }
}
#endif
