#if canImport(UIKit) || os(macOS)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
import SwiftUI
#endif

/// The error prompt's UI half (contract §3.6): it reads the key's config at start, turns the gate on
/// when the key and the options both allow it, and shows the pill when the gate says so. The rules
/// themselves are `ErrorPromptGate`'s, in the core.
@MainActor
enum ErrorPromptUI {
  static let visibleFor: TimeInterval = 8
  private static var startedAt = Date()
  private static var loopRunning = false
  private static var keyboardUp = false
  private static var lastTextEditAt: Date?
  private static var observers: [NSObjectProtocol] = []
  private static var pill: PromptPill?

  /// At `start`: applies the kept config at once, then reads the door and applies its answer.
  static func start() {
    startedAt = Date()
    // Typing holds the prompt back (contract §3.6): the software keyboard on screen, or text changed
    // in any of the app's text inputs in the last five seconds. A field that only has focus does not.
    let center = NotificationCenter.default
    #if canImport(UIKit)
    #if !os(visionOS)
    observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { keyboardUp = true }
    })
    observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { keyboardUp = false }
    })
    #endif
    let edits: [Notification.Name] = [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification]
    #else
    let edits: [Notification.Name] = [NSControl.textDidChangeNotification, NSText.didChangeNotification]
    #endif
    for name in edits {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { lastTextEditAt = Date() }
      })
    }
    apply()
    Task { @MainActor in
      await OverblastFeedback.refreshRemoteConfig()
      apply()
    }
  }

  static func apply() {
    guard let settings = OverblastFeedback.effectiveConfig.errorPrompt, let defaults = OverblastFeedback.sharedDefaults else {
      ErrorPromptCenter.shared.deactivate()
      return
    }
    ErrorPromptCenter.shared.activate(
      startedAt: startedAt,
      settings: settings,
      appHosts: OverblastFeedback.options.appHosts,
      defaults: defaults
    ) {
      Task { @MainActor in ErrorPromptUI.run() }
    }
  }

  /// Asks the gate until it shows the pill or gives up.
  static func run() {
    guard !loopRunning else { return }
    loopRunning = true
    Task { @MainActor in
      defer { loopRunning = false }
      while true {
        switch ErrorPromptCenter.shared.decide(conditions()) {
        case .idle:
          return
        case .wait(let until):
          let seconds = max(0.1, until.timeIntervalSinceNow)
          try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case .show:
          show()
          return
        }
      }
    }
  }

  static func conditions() -> ErrorPromptGate.Conditions {
    #if canImport(UIKit)
    let window = ScreenContext.appWindow()
    return ErrorPromptGate.Conditions(
      isForeground: UIApplication.shared.applicationState == .active,
      isKeyboardUp: keyboardUp,
      lastTextEditAt: lastTextEditAt,
      isBlockingUIShowing: FeedbackPresenter.shared.isPresenting || pill != nil || (window.map(isShowingAlert) ?? false)
    )
    #else
    let window = ScreenContext.appWindow()
    return ErrorPromptGate.Conditions(
      isForeground: NSApplication.shared.isActive,
      lastTextEditAt: lastTextEditAt,
      isBlockingUIShowing: FeedbackPresenter.shared.isPresenting || pill != nil || window?.attachedSheet != nil || NSApplication.shared.modalWindow != nil
    )
    #endif
  }

  #if canImport(UIKit)
  static func isShowingAlert(_ window: UIWindow) -> Bool {
    var vc = window.rootViewController
    while let presented = vc?.presentedViewController {
      if presented is UIAlertController { return true }
      vc = presented
    }
    return false
  }
  #endif

  private static func show() {
    guard pill == nil else { return }
    ErrorPromptCenter.shared.shown()
    OverblastFeedback.log(.info, "error prompt shown", source: FeedbackLogBuffer.source)
    pill = PromptPill.show(
      onReport: {
        ErrorPromptCenter.shared.reported()
        OverblastFeedback.log(.info, "error prompt: reporting", source: FeedbackLogBuffer.source)
        hide()
        OverblastFeedback.present(category: .bug, trigger: .errorPrompt)
      },
      onClose: {
        ErrorPromptCenter.shared.dismissed()
        OverblastFeedback.log(.info, "error prompt dismissed", source: FeedbackLogBuffer.source)
        hide()
      },
      onTimeout: {
        OverblastFeedback.log(.info, "error prompt went by itself", source: FeedbackLogBuffer.source)
        hide()
      }
    )
  }

  static func hide() {
    pill?.remove()
    pill = nil
  }

  static func announce(_ text: String) {
    #if canImport(UIKit)
    // Polite: queued behind whatever VoiceOver is saying, not interrupting it.
    #if os(visionOS)
    let polite: [NSAttributedString.Key: Any] = [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]
    #else
    let polite: [NSAttributedString.Key: Any] = [.accessibilitySpeechQueueAnnouncement: true]
    #endif
    UIAccessibility.post(notification: .announcement, argument: NSAttributedString(string: text, attributes: polite))
    #else
    NSAccessibility.post(element: NSApplication.shared.mainWindow ?? NSApplication.shared, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    #endif
  }
}

#if canImport(UIKit)
/// A window of this library's own that lets every touch through except on the pill.
final class PromptWindow: FeedbackOverlayWindow {
  weak var pillView: UIView?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let pillView, pillView.frame.contains(point) else { return nil }
    return super.hitTest(point, with: event)
  }
}

/// The pill: "Something may have gone wrong. Tell us?", Report, and close, above the bottom safe area
/// and inside the side ones, in the app's tint.
@MainActor
final class PromptPill {
  private let window: PromptWindow
  private var timer: Task<Void, Never>?

  private init(window: PromptWindow) { self.window = window }

  static func show(onReport: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void, onTimeout: @escaping @MainActor () -> Void) -> PromptPill? {
    guard let appWindow = ScreenContext.appWindow(), let scene = appWindow.windowScene else { return nil }
    let window = PromptWindow(windowScene: scene)
    window.frame = appWindow.frame
    window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
    window.backgroundColor = .clear
    window.overrideUserInterfaceStyle = appWindow.overrideUserInterfaceStyle
    window.tintColor = ThemeUI.accent(appWindow)
    let root = UIViewController()
    root.view.backgroundColor = .clear
    window.rootViewController = root

    let pill = UIView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    #if os(visionOS)
    // Glass, like the system's own ornaments.
    pill.backgroundColor = .clear
    let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.clipsToBounds = true
    glass.layer.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 60)
    glass.layer.cornerCurve = .continuous
    pill.addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
      glass.topAnchor.constraint(equalTo: pill.topAnchor),
      glass.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
    ])
    #else
    pill.backgroundColor = .secondarySystemBackground
    #endif
    pill.layer.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 60)
    pill.layer.cornerCurve = .continuous
    pill.layer.shadowColor = UIColor.black.cgColor
    pill.layer.shadowOpacity = 0.18
    pill.layer.shadowRadius = 12
    pill.layer.shadowOffset = CGSize(width: 0, height: 4)
    pill.accessibilityViewIsModal = false

    let label = UILabel()
    label.text = Strings.promptText
    label.font = ThemeUI.font(.subheadline)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.textColor = .label

    var reportConfig = UIButton.Configuration.filled()
    reportConfig.cornerStyle = .capsule
    reportConfig.title = Strings.promptReport
    reportConfig.baseBackgroundColor = ThemeUI.accent(appWindow)
    reportConfig.baseForegroundColor = ThemeUI.onAccent(appWindow)
    reportConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.subheadline, weight: .semibold)
      return a
    }
    let report = UIButton(configuration: reportConfig, primaryAction: UIAction { _ in onReport() })

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.accessibilityLabel = Strings.promptClose
    close.tintColor = .secondaryLabel
    close.addAction(UIAction { _ in onClose() }, for: .primaryActionTriggered)

    let row = UIStackView(arrangedSubviews: [label, report, close])
    row.spacing = 10
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    pill.addSubview(row)
    root.view.addSubview(pill)

    let guide = root.view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
      row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
      close.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      // Inside every safe area, sideways ones included (iPhone Duo's bar column, landscape).
      pill.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
      pill.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      pill.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
      pill.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
    ])
    window.pillView = pill
    // Visible without becoming key: the app keeps its keyboard focus and its first responder.
    window.isHidden = false
    root.view.layoutIfNeeded()

    if UIAccessibility.isReduceMotionEnabled {
      pill.alpha = 1
    } else {
      pill.alpha = 0
      UIView.animate(withDuration: 0.25) { pill.alpha = 1 }
    }
    ErrorPromptUI.announce(Strings.promptText)

    let shown = PromptPill(window: window)
    shown.timer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(ErrorPromptUI.visibleFor * 1_000_000_000))
      if !Task.isCancelled { onTimeout() }
    }
    return shown
  }

  func remove() {
    timer?.cancel()
    let window = self.window
    if UIAccessibility.isReduceMotionEnabled {
      window.isHidden = true
      window.rootViewController = nil
    } else {
      UIView.animate(withDuration: 0.2, animations: { window.pillView?.alpha = 0 }) { _ in
        window.isHidden = true
        window.rootViewController = nil
      }
    }
  }
}
#else
/// The pill on a Mac: a small borderless panel at the bottom right of the window's content, that
/// does not take focus from the window, and stays while the pointer is over it.
@MainActor
final class PromptPill {
  private let panel: NSPanel
  private weak var parent: NSWindow?
  private var timer: Task<Void, Never>?
  private var hovering = false
  private let onTimeout: @MainActor () -> Void

  private init(panel: NSPanel, parent: NSWindow, onTimeout: @escaping @MainActor () -> Void) {
    self.panel = panel
    self.parent = parent
    self.onTimeout = onTimeout
  }

  static func show(onReport: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void, onTimeout: @escaping @MainActor () -> Void) -> PromptPill? {
    guard let parent = ScreenContext.appWindow() else { return nil }
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.appearance = parent.effectiveAppearance
    var shown: PromptPill?
    let view = PromptPillView(onReport: onReport, onClose: onClose) { inside in
      shown?.hover(inside)
    }
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    panel.setContentSize(host.fittingSize)
    panel.contentView = host
    // Bottom right of the window's content, but always whole on the screen: a window smaller than
    // the pill, or partly off screen, does not push it out of sight.
    let size = host.fittingSize
    let content = parent.convertToScreen(parent.contentLayoutRect)
    var origin = NSPoint(x: content.maxX - size.width - 16, y: content.minY + 16)
    if let visible = parent.screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
      origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
    }
    panel.setFrameOrigin(origin)
    parent.addChildWindow(panel, ordered: .above)
    let pill = PromptPill(panel: panel, parent: parent, onTimeout: onTimeout)
    shown = pill
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.alphaValue = 1
    } else {
      panel.alphaValue = 0
      NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
    }
    ErrorPromptUI.announce(Strings.promptText)
    pill.startTimer()
    return pill
  }

  private func startTimer() {
    timer?.cancel()
    timer = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(ErrorPromptUI.visibleFor * 1_000_000_000))
      guard let self, !Task.isCancelled, !self.hovering else { return }
      self.onTimeout()
    }
  }

  /// "Longer if the pointer is over it": the clock starts again when the pointer leaves.
  private func hover(_ inside: Bool) {
    hovering = inside
    if inside { timer?.cancel() } else { startTimer() }
  }

  func remove() {
    timer?.cancel()
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }
}

struct PromptPillView: View {
  let onReport: @MainActor () -> Void
  let onClose: @MainActor () -> Void
  let onHover: @MainActor (Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(Strings.promptText)
        .font(ThemeUI.swiftUIFont(.callout))
        .fixedSize()
      Button(Strings.promptReport) { onReport() }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(ThemeUI.accentColor)
      Button { onClose() } label: { Image(systemName: "xmark") }
        .buttonStyle(.borderless)
        .accessibilityLabel(Strings.promptClose)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: ThemeUI.theme.cornerRadius(forHeight: 36)).fill(Color(nsColor: .windowBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: ThemeUI.theme.cornerRadius(forHeight: 36)).stroke(Color(nsColor: .separatorColor)))
    .onHover { onHover($0) }
    .padding(4)
  }
}
#endif
#endif
