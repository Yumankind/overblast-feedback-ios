#if canImport(UIKit)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import SwiftUI
import UIKit

/// The report sheet, top to bottom: the category chips (only the key's categories, none when it takes
/// one), a large message field, the part pointed at (a thumbnail of it, with Change and Remove), the
/// screenshot (off until the person turns it on; a preview that opens the editor), an email field
/// when the app did not supply one, a line saying exactly what will be sent, and Send in a bar that
/// stays above the keyboard. In the theme's accent, font and radius; Dynamic Type, VoiceOver and
/// Reduce Motion are honoured throughout.
@MainActor
final class FeedbackSheetController: UIViewController, UIAdaptivePresentationControllerDelegate, UITextViewDelegate {
  private let capture: ScreenCapture
  private weak var appWindow: UIWindow?
  private let onFinish: () -> Void
  /// The opener's own handler for each Send's outcome (`present(onResult:)`); the app-wide
  /// `OverblastFeedback.onReportResult` is called after it either way.
  private let onResult: (@MainActor (FeedbackResult) -> Void)?

  private var category: FeedbackCategory
  var selection: ElementPicker.Selection?
  var includeScreenshot = false
  var edits: [ScreenshotEdit] = []
  private var isSending = false
  /// Started when the sheet opens, so the unified log (which can take a second to read) is ready by
  /// the time the person presses Send.
  private var logsTask: Task<[FeedbackLogEntry], Never>?

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let chips = UIStackView()
  private var chipButtons: [UIButton] = []
  let messageView = UITextView()
  private let placeholder = UILabel()
  private let pointButton = UIButton(type: .system)
  private let pickCard = UIView()
  private let pickThumbnail = UIImageView()
  private let pickLabel = UILabel()
  let screenshotSwitch = UISwitch()
  private let thumbnail = UIImageView()
  private let thumbnailRow = UIStackView()
  private let emailField = UITextField()
  private let emailFootnote = UILabel()
  private let willSendLabel = UILabel()
  private let statusLabel = UILabel()
  private let bottomBar = UIView()
  private let sendButton = UIButton(type: .system)

  private let asksForEmail: Bool
  /// The unified log is read up to here: what UIKit logs about this sheet is not the app's.
  let openedAt = Date()

  /// What opened the sheet; `.relaunch` makes it a report about the previous session, which carries
  /// that session's saved logs and how it ended instead of this session's.
  private let trigger: FeedbackTrigger
  private var isAboutPreviousSession: Bool { trigger == .relaunch }

  /// The categories the key takes (contract §2): one means no choice at all.
  private let categories: [(FeedbackCategory, String)]
  private let sheetTitle: String
  private let offersScreenshot: Bool

  init(capture: ScreenCapture, appWindow: UIWindow, category: FeedbackCategory?, message: String, trigger: FeedbackTrigger = .button, onResult: (@MainActor (FeedbackResult) -> Void)? = nil, onFinish: @escaping () -> Void) {
    let config = OverblastFeedback.effectiveConfig
    self.capture = capture
    self.appWindow = appWindow
    self.category = config.category(for: category)
    self.categories = Strings.categories(for: config)
    self.sheetTitle = Strings.title(for: config)
    // The key's owner can switch screenshots off (contract §2.1); then none is offered.
    self.offersScreenshot = config.screenshots
    self.trigger = trigger
    self.onFinish = onFinish
    self.onResult = onResult
    self.asksForEmail = OverblastFeedback.reporter?.email == nil
    super.init(nibName: nil, bundle: nil)
    messageView.text = message
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private var accent: UIColor { ThemeUI.accent(appWindow) }
  private var radius: CGFloat { ThemeUI.radius }

  /// The sheet's own presentation controller (the navigation controller's).
  private var sheet: UISheetPresentationController? {
    #if os(visionOS)
    return nil
    #else
    return navigationController?.sheetPresentationController ?? sheetPresentationController
    #endif
  }

  // MARK: Layout

  override func viewDidLoad() {
    super.viewDidLoad()
    title = sheetTitle
    view.backgroundColor = .systemGroupedBackground
    view.tintColor = accent
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
    navigationController?.navigationBar.titleTextAttributes = [.font: ThemeUI.font(.headline, weight: .semibold)]

    let openedAt = self.openedAt
    if isAboutPreviousSession {
      let saved = OverblastFeedback.previousSession?.logs ?? []
      logsTask = Task { saved }
    } else {
      logsTask = Task.detached(priority: .utility) { await OverblastFeedback.collectLogs(until: openedAt) }
    }

    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = true
    #if !os(visionOS)
    scroll.keyboardDismissMode = .interactive
    #endif
    view.addSubview(scroll)

    stack.axis = .vertical
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)

    buildBottomBar()

    NSLayoutConstraint.activate([
      // Horizontally inside the safe area: on a display with a system bar down one side (iPhone
      // Duo's closed display, landscape with the sensor housing) UIKit moves the clock and the bar
      // buttons into that column, and the sheet's content must not run under them.
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
    ])

    if categories.count > 1 { buildChips() }
    buildMessage()
    buildElement()
    if offersScreenshot { buildScreenshot() }
    if asksForEmail { buildEmail() }
    buildFooter()
    refresh()

    #if !os(visionOS)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
    #endif
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // On a phone the sheet opens at half height and the keyboard would take it straight to full; it
    // waits for a tap in the field instead. Where the sheet is a form sheet (iPad, Vision Pro), the
    // field is ready at once.
    if messageView.text.isEmpty, traitCollection.horizontalSizeClass == .regular { messageView.becomeFirstResponder() }
  }

  /// Grows the sheet to full height (the keyboard rose, or the content now needs the room).
  func growToLarge() {
    #if !os(visionOS)
    guard let sheet, sheet.selectedDetentIdentifier != .large else { return }
    let change = { sheet.selectedDetentIdentifier = .large }
    if UIAccessibility.isReduceMotionEnabled { change() } else { sheet.animateChanges(change) }
    #endif
  }

  @objc private func keyboardWillShow(_ note: Notification) {
    growToLarge()
  }

  private func buildChips() {
    chips.axis = .horizontal
    chips.spacing = 8
    chips.alignment = .center
    chips.distribution = .fill
    chips.accessibilityLabel = Strings.category
    chips.shouldGroupAccessibilityChildren = true
    for (index, item) in categories.enumerated() {
      let chip = UIButton(type: .system)
      chip.tag = index
      chip.addAction(UIAction { [weak self] action in
        guard let self, let button = action.sender as? UIButton else { return }
        self.category = self.categories[button.tag].0
        self.styleChips()
        #if !os(visionOS)
      UISelectionFeedbackGenerator().selectionChanged()
      #endif
      }, for: .primaryActionTriggered)
      chip.accessibilityLabel = item.1
      chip.setContentHuggingPriority(.required, for: .horizontal)
      chip.setContentCompressionResistancePriority(.required, for: .horizontal)
      chipButtons.append(chip)
      chips.addArrangedSubview(chip)
    }
    let scroller = UIScrollView()
    scroller.showsHorizontalScrollIndicator = false
    scroller.translatesAutoresizingMaskIntoConstraints = false
    chips.translatesAutoresizingMaskIntoConstraints = false
    scroller.addSubview(chips)
    NSLayoutConstraint.activate([
      chips.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
      chips.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
      chips.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
      chips.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
      scroller.heightAnchor.constraint(equalTo: chips.heightAnchor),
    ])
    stack.addArrangedSubview(scroller)
    styleChips()
  }

  private func styleChips() {
    for chip in chipButtons {
      let (value, name) = categories[chip.tag]
      let selected = value == category
      var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
      config.title = name
      config.baseBackgroundColor = selected ? accent : nil
      config.baseForegroundColor = selected ? ThemeUI.onAccent(appWindow) : .label
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
      config.buttonSize = .small
      config.background.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 36)
      config.cornerStyle = .fixed
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
        var a = a
        a.font = ThemeUI.font(.subheadline, weight: selected ? .semibold : .regular)
        return a
      }
      chip.configuration = config
      chip.accessibilityTraits = selected ? [.button, .selected] : [.button]
      #if os(visionOS)
      chip.hoverStyle = UIHoverStyle(shape: .capsule)
      #endif
    }
  }

  private func buildMessage() {
    messageView.font = ThemeUI.font(.body)
    messageView.adjustsFontForContentSizeCategory = true
    messageView.backgroundColor = .secondarySystemGroupedBackground
    messageView.textColor = .label
    messageView.tintColor = accent
    messageView.layer.cornerRadius = radius
    messageView.layer.cornerCurve = .continuous
    messageView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
    messageView.isScrollEnabled = false
    messageView.delegate = self
    messageView.accessibilityLabel = Strings.messageLabel
    messageView.accessibilityHint = Strings.messagePlaceholder
    messageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

    placeholder.text = isAboutPreviousSession ? Strings.crashPlaceholder : Strings.messagePlaceholder
    placeholder.font = ThemeUI.font(.body)
    placeholder.adjustsFontForContentSizeCategory = true
    placeholder.textColor = .placeholderText
    placeholder.numberOfLines = 0
    placeholder.isAccessibilityElement = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    messageView.addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 15),
      // The width from the field's frame: a text view is a scroll view, and its own trailing edge is
      // its content's, so a long placeholder at a large text size would run off instead of wrapping.
      placeholder.widthAnchor.constraint(equalTo: messageView.widthAnchor, constant: -30),
      placeholder.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 14),
    ])
    stack.addArrangedSubview(messageView)
  }

  private func buildElement() {
    var config = UIButton.Configuration.gray()
    config.image = UIImage(systemName: "hand.point.up.left")
    config.imagePadding = 10
    config.title = Strings.point
    config.baseForegroundColor = accent
    config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    config.background.cornerRadius = radius
    config.cornerStyle = .fixed
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.body, weight: .medium)
      return a
    }
    pointButton.configuration = config
    pointButton.contentHorizontalAlignment = .leading
    pointButton.addAction(UIAction { [weak self] _ in self?.openPointer() }, for: .primaryActionTriggered)

    // The pick, once there is one: a thumbnail of that part of the frozen screenshot with the box on
    // it, what it is, and Change and Remove.
    pickCard.backgroundColor = .secondarySystemGroupedBackground
    pickCard.layer.cornerRadius = radius
    pickCard.layer.cornerCurve = .continuous
    pickThumbnail.contentMode = .scaleAspectFill
    pickThumbnail.clipsToBounds = true
    pickThumbnail.layer.cornerRadius = min(radius, 10)
    pickThumbnail.layer.cornerCurve = .continuous
    pickThumbnail.isAccessibilityElement = false
    pickThumbnail.translatesAutoresizingMaskIntoConstraints = false
    pickLabel.font = ThemeUI.font(.subheadline, weight: .medium)
    pickLabel.adjustsFontForContentSizeCategory = true
    pickLabel.numberOfLines = 2
    let change = smallButton(Strings.change, hint: Strings.pickChangeHint) { [weak self] in self?.openPointer() }
    let remove = smallButton(Strings.remove, hint: Strings.pickRemoveHint, destructive: true) { [weak self] in
      self?.selection = nil
      self?.refresh()
    }
    let actions = UIStackView(arrangedSubviews: [change, remove])
    actions.spacing = 4
    let text = UIStackView(arrangedSubviews: [pickLabel, actions])
    text.axis = .vertical
    text.spacing = 2
    text.alignment = .leading
    let row = UIStackView(arrangedSubviews: [pickThumbnail, text])
    row.spacing = 12
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    pickCard.addSubview(row)
    NSLayoutConstraint.activate([
      pickThumbnail.widthAnchor.constraint(equalToConstant: 64),
      pickThumbnail.heightAnchor.constraint(equalToConstant: 64),
      row.leadingAnchor.constraint(equalTo: pickCard.leadingAnchor, constant: 10),
      row.trailingAnchor.constraint(equalTo: pickCard.trailingAnchor, constant: -10),
      row.topAnchor.constraint(equalTo: pickCard.topAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: pickCard.bottomAnchor, constant: -10),
    ])

    stack.addArrangedSubview(pointButton)
    stack.addArrangedSubview(pickCard)
  }

  private func smallButton(_ title: String, hint: String, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.baseForegroundColor = destructive ? .systemRed : accent
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 12)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.subheadline)
      return a
    }
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    button.accessibilityHint = hint
    return button
  }

  private func buildScreenshot() {
    let label = UILabel()
    label.text = Strings.includeScreenshot
    label.font = ThemeUI.font(.body)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.isAccessibilityElement = false
    screenshotSwitch.isOn = false
    screenshotSwitch.onTintColor = accent
    screenshotSwitch.accessibilityLabel = Strings.includeScreenshot
    screenshotSwitch.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.includeScreenshot = self.screenshotSwitch.isOn
      if self.includeScreenshot { self.growToLarge() }
      self.refresh()
    }, for: .valueChanged)
    let row = UIStackView(arrangedSubviews: [label, screenshotSwitch])
    row.alignment = .center
    row.spacing = 12

    // The preview opens the editor (cover or blur parts).
    thumbnail.contentMode = .scaleAspectFit
    thumbnail.backgroundColor = .tertiarySystemGroupedBackground
    thumbnail.layer.cornerRadius = radius
    thumbnail.layer.cornerCurve = .continuous
    thumbnail.clipsToBounds = true
    thumbnail.isUserInteractionEnabled = true
    thumbnail.isAccessibilityElement = true
    thumbnail.accessibilityLabel = Strings.screenshotPreview
    thumbnail.accessibilityHint = Strings.editScreenshotHint
    thumbnail.accessibilityTraits = [.image, .button]
    thumbnail.heightAnchor.constraint(equalToConstant: 200).isActive = true
    thumbnail.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openEditor)))
    #if os(visionOS)
    thumbnail.hoverStyle = UIHoverStyle(shape: .rect(cornerRadius: radius))
    #endif

    let edit = smallButton(Strings.editScreenshot, hint: Strings.editScreenshotHint) { [weak self] in self?.openEditor() }
    let remove = smallButton(Strings.remove, hint: Strings.removeScreenshotHint, destructive: true) { [weak self] in
      guard let self else { return }
      self.screenshotSwitch.setOn(false, animated: !UIAccessibility.isReduceMotionEnabled)
      self.includeScreenshot = false
      self.refresh()
    }
    let actions = UIStackView(arrangedSubviews: [edit, remove])
    actions.spacing = 8

    thumbnailRow.axis = .vertical
    thumbnailRow.spacing = 4
    thumbnailRow.alignment = .leading
    thumbnailRow.addArrangedSubview(thumbnail)
    thumbnailRow.addArrangedSubview(actions)
    thumbnail.widthAnchor.constraint(equalTo: thumbnailRow.widthAnchor).isActive = true

    let group = UIStackView(arrangedSubviews: [row, thumbnailRow])
    group.axis = .vertical
    group.spacing = 8
    stack.addArrangedSubview(group)
  }

  private func buildEmail() {
    emailField.placeholder = Strings.emailPlaceholder
    emailField.font = ThemeUI.font(.body)
    emailField.adjustsFontForContentSizeCategory = true
    emailField.keyboardType = .emailAddress
    emailField.textContentType = .emailAddress
    emailField.autocapitalizationType = .none
    emailField.autocorrectionType = .no
    emailField.borderStyle = .none
    emailField.backgroundColor = .secondarySystemGroupedBackground
    emailField.layer.cornerRadius = radius
    emailField.layer.cornerCurve = .continuous
    emailField.tintColor = accent
    let pad = { UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1)) }
    emailField.leftView = pad()
    emailField.leftViewMode = .always
    emailField.rightView = pad()
    emailField.rightViewMode = .always
    emailField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    emailField.accessibilityLabel = Strings.emailPlaceholder
    emailField.accessibilityHint = Strings.emailFootnote
    emailField.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .editingChanged)

    emailFootnote.text = Strings.emailFootnote
    emailFootnote.font = ThemeUI.font(.footnote)
    emailFootnote.adjustsFontForContentSizeCategory = true
    emailFootnote.textColor = .secondaryLabel
    emailFootnote.numberOfLines = 0
    emailFootnote.isAccessibilityElement = false

    let group = UIStackView(arrangedSubviews: [emailField, emailFootnote])
    group.axis = .vertical
    group.spacing = 6
    stack.addArrangedSubview(group)
  }

  private func buildFooter() {
    willSendLabel.font = ThemeUI.font(.footnote)
    willSendLabel.adjustsFontForContentSizeCategory = true
    willSendLabel.textColor = .secondaryLabel
    willSendLabel.numberOfLines = 0

    statusLabel.font = ThemeUI.font(.callout)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.textColor = .systemRed
    statusLabel.isHidden = true

    stack.addArrangedSubview(willSendLabel)
    stack.addArrangedSubview(statusLabel)
  }

  /// Send, in a bar pinned to the top of the keyboard (or of the bottom safe area when there is no
  /// keyboard), so it is never behind either.
  private func buildBottomBar() {
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    #if os(visionOS)
    bottomBar.backgroundColor = .clear
    #else
    bottomBar.backgroundColor = .systemGroupedBackground
    let hairline = UIView()
    hairline.backgroundColor = .separator
    hairline.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(hairline)
    NSLayoutConstraint.activate([
      hairline.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
      hairline.topAnchor.constraint(equalTo: bottomBar.topAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
    ])
    #endif
    view.addSubview(bottomBar)

    sendButton.translatesAutoresizingMaskIntoConstraints = false
    sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)
    bottomBar.addSubview(sendButton)
    styleSend()

    NSLayoutConstraint.activate([
      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      sendButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      sendButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      sendButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),
      sendButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -10),
      sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
    ])
  }

  private func styleSend() {
    var config = UIButton.Configuration.filled()
    config.title = isSending ? Strings.sending : Strings.send
    config.showsActivityIndicator = isSending
    config.imagePadding = 8
    config.baseBackgroundColor = accent
    config.baseForegroundColor = ThemeUI.onAccent(appWindow)
    config.background.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 50)
    config.cornerStyle = .fixed
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.headline, weight: .semibold)
      return a
    }
    sendButton.configuration = config
    sendButton.isEnabled = !trimmedMessage.isEmpty && !isSending
  }

  // MARK: State

  private var trimmedMessage: String {
    messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var typedEmail: String? {
    guard asksForEmail else { return nil }
    let e = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return e.isEmpty ? nil : e
  }

  /// The frozen screenshot with the reporter's covers and blurs applied (the masks stay on top).
  private var editedCapture: ScreenCapture {
    guard !edits.isEmpty, let cg = capture.image.cgImage else { return capture }
    let image = ScreenshotRedaction.apply(edits, to: cg, pointSize: capture.windowSize, masks: capture.privateRects, maskGray: 0.18)
    return ScreenCapture(image: UIImage(cgImage: image, scale: capture.image.scale, orientation: .up), windowSize: capture.windowSize, privateRects: capture.privateRects)
  }

  func refresh() {
    placeholder.isHidden = !messageView.text.isEmpty

    if let selection {
      pickLabel.text = Strings.selected(selection.element)
      pickThumbnail.image = pickImage(for: selection)
      pickCard.isHidden = false
      pickCard.accessibilityLabel = Strings.selected(selection.element)
      pointButton.isHidden = true
    } else {
      pickCard.isHidden = true
      pointButton.isHidden = false
    }

    thumbnailRow.isHidden = !includeScreenshot
    if includeScreenshot {
      thumbnail.image = previewImage()
      thumbnail.accessibilityLabel = edits.isEmpty ? Strings.screenshotPreview : Strings.screenshotEdited
    }

    willSendLabel.text = Strings.willSend(
      element: selection != nil,
      screenshot: includeScreenshot,
      logs: OverblastFeedback.options.includeLogs,
      email: typedEmail != nil || OverblastFeedback.reporter?.email != nil,
      crash: isAboutPreviousSession
    )

    ([pointButton, screenshotSwitch, emailField] + chipButtons).forEach { $0.isEnabled = !isSending }
    messageView.isEditable = !isSending
    styleSend()
  }

  /// The part of the frozen screenshot round the pick, with its box drawn.
  private func pickImage(for selection: ElementPicker.Selection) -> UIImage {
    let boxed = ScreenshotRenderer.highlighted(editedCapture.image, rect: selection.frame, color: accent)
    let crop = PickThumbnail.cropRect(for: selection.frame, in: capture.windowSize)
    let scale = boxed.scale
    guard let cg = boxed.cgImage,
          let part = cg.cropping(to: PickThumbnail.pixelRect(crop, scale: scale, pixelSize: CGSize(width: cg.width, height: cg.height)))
    else { return boxed }
    return UIImage(cgImage: part, scale: scale, orientation: .up)
  }

  private func previewImage() -> UIImage {
    let image = editedCapture.image
    guard let selection else { return image }
    return ScreenshotRenderer.highlighted(image, rect: selection.frame, color: accent)
  }

  // MARK: Actions

  func textViewDidChange(_ textView: UITextView) {
    refresh()
  }

  private func openPointer() {
    guard let appWindow else { return }
    view.endEditing(true)
    let pointer = PointerViewController(image: editedCapture.image, appWindow: appWindow, privateRects: capture.privateRects, selection: selection) { [weak self] picked in
      self?.selection = picked
      self?.refresh()
    }
    present(pointer, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  @objc private func openEditor() {
    guard let cg = capture.image.cgImage else { return }
    view.endEditing(true)
    let model = ScreenshotEditorModel(original: cg, pointSize: capture.windowSize, masks: capture.privateRects, edits: edits)
    let host = UIHostingController(rootView: ScreenshotEditorView(model: model))
    host.modalPresentationStyle = .fullScreen
    host.view.tintColor = accent
    model.onFinish = { [weak self, weak host] result in
      if let result { self?.edits = result }
      self?.refresh()
      host?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
    present(host, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  private func cancel() {
    logsTask?.cancel()
    // The offer is made once: cancelling the report about the previous session is an answer too.
    if isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    onFinish()
  }

  private func send() {
    guard !isSending, !trimmedMessage.isEmpty else { return }
    isSending = true
    isModalInPresentation = true
    statusLabel.isHidden = true
    view.endEditing(true)
    refresh()

    let element = selection?.element
    let screenshot = includeScreenshot ? ScreenshotRenderer.screenshot(from: editedCapture, element: element, color: accent) : nil
    let reporter = typedEmail.map { FeedbackReporter(email: $0) }
    let message = messageView.text ?? ""
    let category = self.category
    let logsTask = self.logsTask
    let trigger = self.trigger
    let openedAt = self.openedAt
    // Decided at Send, so a MetricKit diagnostic that arrived while the person typed is in it.
    let crash = isAboutPreviousSession ? OverblastFeedback.previousSessionCrash : nil
    let messages = OverblastFeedback.options.messages

    let onResult = self.onResult

    Task { @MainActor [weak self] in
      let logs = await logsTask?.value
      let result: FeedbackResult
      do {
        result = .success(try await OverblastFeedback.report(
          message: message,
          category: category,
          reporter: reporter,
          element: element,
          screenshot: screenshot,
          logs: logs ?? [],
          trigger: trigger,
          openedAt: openedAt,
          crash: crash
        ))
      } catch {
        result = .failure(OverblastFeedback.feedbackError(from: error))
      }
      // The app hears the outcome even when the sheet has gone in the meantime.
      OverblastFeedback.deliverReportResult(result, to: onResult)
      switch result {
      case let .success(receipt):
        self?.finishSending(text: messages.thankYou(for: receipt), symbol: "checkmark.circle.fill", close: true)
      case let .failure(error) where error.keepsForLater:
        self?.finishSending(text: "\(error.message) \(Strings.savedForLater)", symbol: "clock.arrow.circlepath", close: true)
      case let .failure(error) where error.wasFiled:
        self?.finishSending(text: error.message, symbol: "checkmark.circle.fill", close: true)
      case let .failure(error):
        self?.finishSending(text: error.message, symbol: nil, close: false)
      }
    }
  }

  private func finishSending(text: String, symbol: String?, close: Bool) {
    if close, isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    isSending = false
    if close, let symbol {
      showConfirmation(text, symbol: symbol)
      return
    }
    // A refusal: the sheet stays, with the service's own sentence.
    isModalInPresentation = false
    statusLabel.text = text
    statusLabel.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: text)
    refresh()
    scroll.scrollRectToVisible(statusLabel.frame.insetBy(dx: 0, dy: -20), animated: !UIAccessibility.isReduceMotionEnabled)
  }

  /// "Sent. Thank you." with a checkmark over the whole sheet for a moment and a VoiceOver
  /// announcement, then the sheet goes.
  /// The confirmation's clock: timed to its sentence, held by hover (visionOS) or VoiceOver on Done.
  private(set) var confirmationTimer: ConfirmationTimer?
  private weak var doneButton: UIButton?
  private var announcementObserver: NSObjectProtocol?
  private var focusObserver: NSObjectProtocol?

  /// "Sent. Thank you." with a checkmark over the whole sheet and a Done button. It closes on Done,
  /// the close button, a swipe down, or by itself once the sentence has had time to be read; the
  /// pointer over it (visionOS) or VoiceOver on Done holds it. VoiceOver reads the sentence, then its
  /// focus lands on Done.
  func showConfirmation(_ text: String, symbol: String) {
    let overlay = UIView()
    overlay.backgroundColor = .systemGroupedBackground
    overlay.translatesAutoresizingMaskIntoConstraints = false
    let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold)))
    icon.tintColor = accent
    icon.isAccessibilityElement = false
    let label = UILabel()
    label.text = text
    label.font = ThemeUI.font(.title3, weight: .semibold)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.textAlignment = .center

    var config = UIButton.Configuration.filled()
    config.title = Strings.done
    config.baseBackgroundColor = accent
    config.baseForegroundColor = ThemeUI.onAccent(appWindow)
    config.background.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 44)
    config.cornerStyle = .fixed
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 28)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.headline, weight: .semibold)
      return a
    }
    let done = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.closeConfirmation(.done) })
    done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    doneButton = done

    let column = UIStackView(arrangedSubviews: [icon, label, done])
    column.axis = .vertical
    column.spacing = 14
    column.setCustomSpacing(24, after: label)
    column.alignment = .center
    column.translatesAutoresizingMaskIntoConstraints = false
    overlay.addSubview(column)
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      column.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      column.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      column.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      column.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
    ])
    // The close button stays, and closes at once; a swipe down still dismisses the sheet.
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.closeConfirmation(.closeButton) })
    isModalInPresentation = false
    // Two even lines rather than a full one and a lonely word.
    label.balance(within: view.safeAreaLayoutGuide.layoutFrame.width - 48)
    label.widthAnchor.constraint(lessThanOrEqualToConstant: max(label.preferredMaxLayoutWidth, 1)).isActive = true
    view.layoutIfNeeded()
    if UIAccessibility.isReduceMotionEnabled {
      overlay.alpha = 1
    } else {
      overlay.alpha = 0
      icon.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
      UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
        overlay.alpha = 1
        icon.transform = .identity
      }
    }
    #if !os(visionOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif

    confirmationTimer = ConfirmationTimer(text: text, startedAt: Date())
    #if os(visionOS)
    overlay.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(confirmationHover(_:))))
    #endif
    // VoiceOver: the sentence first, then focus on Done; while it is there, the clock waits.
    let center = NotificationCenter.default
    announcementObserver = center.addObserver(forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main) { [weak done] _ in
      MainActor.assumeIsolated { if let done { UIAccessibility.post(notification: .layoutChanged, argument: done) } }
    }
    focusObserver = center.addObserver(forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main) { [weak self] note in
      // Only the focused element's identity crosses into the main actor.
      let focused = (note.userInfo?[UIAccessibility.focusedElementUserInfoKey] as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, let done = self.doneButton else { return }
        if focused == ObjectIdentifier(done) {
          self.confirmationTimer?.hold(.voiceOverFocus, at: Date())
        } else {
          self.confirmationTimer?.release(.voiceOverFocus, at: Date())
        }
      }
    }
    UIAccessibility.post(notification: .announcement, argument: text)
    Task { @MainActor [weak self] in
      while let self, self.confirmationTimer?.closedBy == nil {
        if self.confirmationTimer?.tick(at: Date()) == true {
          self.finishConfirmation()
          return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  #if os(visionOS)
  @objc private func confirmationHover(_ gesture: UIHoverGestureRecognizer) {
    switch gesture.state {
    case .began, .changed: confirmationTimer?.hold(.hover, at: Date())
    default: confirmationTimer?.release(.hover, at: Date())
    }
  }
  #endif

  /// Done, the close button or a swipe: closes now, once.
  func closeConfirmation(_ reason: ConfirmationTimer.CloseReason) {
    guard confirmationTimer?.close(reason) == true else { return }
    finishConfirmation()
  }

  private func finishConfirmation() {
    [announcementObserver, focusObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
    announcementObserver = nil
    focusObserver = nil
    onFinish()
  }

  // MARK: UIAdaptivePresentationControllerDelegate

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // A swipe down on the confirmation is a close like any other.
    if confirmationTimer?.close(.swipe) == true {
      [announcementObserver, focusObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
    }
    logsTask?.cancel()
    if isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    FeedbackPresenter.shared.tearDown()
  }
}
#endif
