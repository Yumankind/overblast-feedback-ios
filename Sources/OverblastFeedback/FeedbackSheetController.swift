#if canImport(UIKit)
import UIKit

/// The report sheet: message, category, the element, the screenshot (off until the person turns it
/// on), an email field when the app did not supply one, a line saying exactly what will be sent, and
/// Send. Built from system fonts and colours, so Dynamic Type, dark mode and VoiceOver come with it.
@MainActor
final class FeedbackSheetController: UIViewController, UIAdaptivePresentationControllerDelegate, UITextViewDelegate {
  private let capture: ScreenCapture
  private weak var appWindow: UIWindow?
  private let onFinish: () -> Void

  private var category: FeedbackCategory
  private var selection: ElementPicker.Selection?
  private var includeScreenshot = false
  private var isSending = false
  /// Started when the sheet opens, so the unified log (which can take a second to read) is ready by
  /// the time the person presses Send.
  private var logsTask: Task<[FeedbackLogEntry], Never>?

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let messageView = UITextView()
  private let placeholder = UILabel()
  private let categoryControl = UISegmentedControl()
  private let pointButton = UIButton(type: .system)
  private let selectionLabel = UILabel()
  private let clearButton = UIButton(type: .system)
  private let screenshotSwitch = UISwitch()
  private let thumbnail = UIImageView()
  private let removeButton = UIButton(type: .system)
  private let thumbnailRow = UIStackView()
  private let emailField = UITextField()
  private let emailFootnote = UILabel()
  private let willSendLabel = UILabel()
  private let statusLabel = UILabel()

  private let asksForEmail: Bool

  init(capture: ScreenCapture, appWindow: UIWindow, category: FeedbackCategory, message: String, onFinish: @escaping () -> Void) {
    self.capture = capture
    self.appWindow = appWindow
    self.category = category
    self.onFinish = onFinish
    self.asksForEmail = OverblastFeedback.reporter?.email == nil
    super.init(nibName: nil, bundle: nil)
    messageView.text = message
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  // MARK: Layout

  override func viewDidLoad() {
    super.viewDidLoad()
    title = Strings.title
    view.backgroundColor = .systemGroupedBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
    setSendItem()

    logsTask = Task.detached(priority: .utility) { await OverblastFeedback.collectLogs() }

    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = true
    scroll.keyboardDismissMode = .interactive
    view.addSubview(scroll)

    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)

    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
    ])

    buildCategory()
    buildMessage()
    buildElement()
    buildScreenshot()
    if asksForEmail { buildEmail() }
    buildFooter()
    refresh()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if messageView.text.isEmpty { messageView.becomeFirstResponder() }
  }

  private func buildCategory() {
    for (index, item) in Strings.categories.enumerated() {
      categoryControl.insertSegment(withTitle: item.1, at: index, animated: false)
      if item.0 == category { categoryControl.selectedSegmentIndex = index }
    }
    categoryControl.accessibilityLabel = Strings.category
    categoryControl.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.category = Strings.categories[self.categoryControl.selectedSegmentIndex].0
    }, for: .valueChanged)
    stack.addArrangedSubview(categoryControl)
  }

  private func buildMessage() {
    messageView.font = .preferredFont(forTextStyle: .body)
    messageView.adjustsFontForContentSizeCategory = true
    messageView.backgroundColor = .secondarySystemGroupedBackground
    messageView.textColor = .label
    messageView.layer.cornerRadius = 10
    messageView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
    messageView.isScrollEnabled = false
    messageView.delegate = self
    messageView.accessibilityLabel = Strings.messageLabel
    messageView.accessibilityHint = Strings.messagePlaceholder
    messageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

    placeholder.text = Strings.messagePlaceholder
    placeholder.font = .preferredFont(forTextStyle: .body)
    placeholder.adjustsFontForContentSizeCategory = true
    placeholder.textColor = .placeholderText
    placeholder.numberOfLines = 0
    placeholder.isAccessibilityElement = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    messageView.addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 13),
      placeholder.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -13),
      placeholder.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 12),
    ])
    stack.addArrangedSubview(messageView)
  }

  private func buildElement() {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "hand.point.up.left")
    config.imagePadding = 8
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var a = attributes
      a.font = UIFont.preferredFont(forTextStyle: .body)
      return a
    }
    pointButton.configuration = config
    pointButton.setTitle(Strings.point, for: .normal)
    pointButton.contentHorizontalAlignment = .leading
    pointButton.addAction(UIAction { [weak self] _ in self?.openPointer() }, for: .primaryActionTriggered)

    selectionLabel.font = .preferredFont(forTextStyle: .footnote)
    selectionLabel.adjustsFontForContentSizeCategory = true
    selectionLabel.textColor = .secondaryLabel
    selectionLabel.numberOfLines = 0

    clearButton.setTitle(Strings.clearSelection, for: .normal)
    clearButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
    clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
    clearButton.accessibilityLabel = "Clear the selected element"
    clearButton.addAction(UIAction { [weak self] _ in
      self?.selection = nil
      self?.refresh()
    }, for: .primaryActionTriggered)

    let row = UIStackView(arrangedSubviews: [selectionLabel, clearButton])
    row.spacing = 8
    row.alignment = .firstBaseline
    selectionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let group = UIStackView(arrangedSubviews: [pointButton, row])
    group.axis = .vertical
    group.spacing = 4
    stack.addArrangedSubview(group)
  }

  private func buildScreenshot() {
    let label = UILabel()
    label.text = Strings.includeScreenshot
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
    label.isAccessibilityElement = false
    screenshotSwitch.isOn = false
    screenshotSwitch.accessibilityLabel = Strings.includeScreenshot
    screenshotSwitch.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.includeScreenshot = self.screenshotSwitch.isOn
      self.refresh()
    }, for: .valueChanged)
    let row = UIStackView(arrangedSubviews: [label, screenshotSwitch])
    row.alignment = .center
    row.spacing = 12

    thumbnail.contentMode = .scaleAspectFit
    thumbnail.layer.cornerRadius = 8
    thumbnail.layer.borderColor = UIColor.separator.cgColor
    thumbnail.layer.borderWidth = 1 / max(view.traitCollection.displayScale, 1)
    thumbnail.clipsToBounds = true
    thumbnail.isAccessibilityElement = true
    thumbnail.accessibilityLabel = Strings.screenshotPreview
    thumbnail.accessibilityTraits = .image
    thumbnail.heightAnchor.constraint(equalToConstant: 200).isActive = true

    removeButton.setTitle(Strings.remove, for: .normal)
    removeButton.accessibilityLabel = "Remove the screenshot"
    removeButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
    removeButton.titleLabel?.adjustsFontForContentSizeCategory = true
    removeButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.screenshotSwitch.setOn(false, animated: true)
      self.includeScreenshot = false
      self.refresh()
    }, for: .primaryActionTriggered)

    thumbnailRow.axis = .vertical
    thumbnailRow.spacing = 4
    thumbnailRow.alignment = .center
    thumbnailRow.addArrangedSubview(thumbnail)
    thumbnailRow.addArrangedSubview(removeButton)
    thumbnail.widthAnchor.constraint(equalTo: thumbnailRow.widthAnchor).isActive = true

    let group = UIStackView(arrangedSubviews: [row, thumbnailRow])
    group.axis = .vertical
    group.spacing = 8
    stack.addArrangedSubview(group)
  }

  private func buildEmail() {
    emailField.placeholder = Strings.emailPlaceholder
    emailField.font = .preferredFont(forTextStyle: .body)
    emailField.adjustsFontForContentSizeCategory = true
    emailField.keyboardType = .emailAddress
    emailField.textContentType = .emailAddress
    emailField.autocapitalizationType = .none
    emailField.autocorrectionType = .no
    emailField.borderStyle = .roundedRect
    emailField.backgroundColor = .secondarySystemGroupedBackground
    emailField.accessibilityLabel = Strings.emailPlaceholder
    emailField.accessibilityHint = Strings.emailFootnote
    emailField.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .editingChanged)

    emailFootnote.text = Strings.emailFootnote
    emailFootnote.font = .preferredFont(forTextStyle: .footnote)
    emailFootnote.adjustsFontForContentSizeCategory = true
    emailFootnote.textColor = .secondaryLabel
    emailFootnote.numberOfLines = 0
    emailFootnote.isAccessibilityElement = false

    let group = UIStackView(arrangedSubviews: [emailField, emailFootnote])
    group.axis = .vertical
    group.spacing = 4
    stack.addArrangedSubview(group)
  }

  private func buildFooter() {
    willSendLabel.font = .preferredFont(forTextStyle: .footnote)
    willSendLabel.adjustsFontForContentSizeCategory = true
    willSendLabel.textColor = .secondaryLabel
    willSendLabel.numberOfLines = 0

    statusLabel.font = .preferredFont(forTextStyle: .callout)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.isHidden = true

    stack.addArrangedSubview(willSendLabel)
    stack.addArrangedSubview(statusLabel)
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

  private func refresh() {
    placeholder.isHidden = !messageView.text.isEmpty
    navigationItem.rightBarButtonItem?.isEnabled = !trimmedMessage.isEmpty && !isSending

    if let selection {
      selectionLabel.text = Strings.selected(selection.element)
      selectionLabel.isHidden = false
      clearButton.isHidden = false
      pointButton.setTitle(Strings.pointAgain, for: .normal)
    } else {
      selectionLabel.isHidden = true
      clearButton.isHidden = true
      pointButton.setTitle(Strings.point, for: .normal)
    }

    thumbnailRow.isHidden = !includeScreenshot
    if includeScreenshot {
      thumbnail.image = previewImage()
    }

    willSendLabel.text = Strings.willSend(
      element: selection != nil,
      screenshot: includeScreenshot,
      logs: OverblastFeedback.options.includeLogs,
      email: typedEmail != nil || OverblastFeedback.reporter?.email != nil
    )

    [categoryControl, pointButton, clearButton, screenshotSwitch, removeButton, emailField].forEach { $0.isEnabled = !isSending }
    messageView.isEditable = !isSending
  }

  private func previewImage() -> UIImage {
    guard let selection else { return capture.image }
    return ScreenshotRenderer.highlighted(capture.image, rect: selection.frame)
  }

  private func setSendItem() {
    if isSending {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      spinner.accessibilityLabel = Strings.sending
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      let send = UIBarButtonItem(title: Strings.send, primaryAction: UIAction { [weak self] _ in self?.send() })
      send.style = .done
      navigationItem.rightBarButtonItem = send
    }
  }

  private func show(_ text: String, error: Bool) {
    statusLabel.text = text
    statusLabel.textColor = error ? .systemRed : .label
    statusLabel.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: text)
    scroll.scrollRectToVisible(statusLabel.frame.insetBy(dx: 0, dy: -20), animated: true)
  }

  // MARK: Actions

  func textViewDidChange(_ textView: UITextView) {
    refresh()
  }

  private func openPointer() {
    guard let appWindow else { return }
    view.endEditing(true)
    let pointer = PointerViewController(image: capture.image, appWindow: appWindow, privateRects: capture.privateRects, selection: selection) { [weak self] picked in
      self?.selection = picked
      self?.refresh()
    }
    present(pointer, animated: true)
  }

  private func cancel() {
    logsTask?.cancel()
    onFinish()
  }

  private func send() {
    guard !isSending, !trimmedMessage.isEmpty else { return }
    isSending = true
    isModalInPresentation = true
    statusLabel.isHidden = true
    setSendItem()
    refresh()

    let element = selection?.element
    let screenshot = includeScreenshot ? ScreenshotRenderer.screenshot(from: capture, element: element) : nil
    let reporter = typedEmail.map { FeedbackReporter(email: $0) }
    let message = messageView.text ?? ""
    let category = self.category
    let logsTask = self.logsTask

    Task { @MainActor [weak self] in
      let logs = await logsTask?.value
      do {
        _ = try await OverblastFeedback.report(
          message: message,
          category: category,
          reporter: reporter,
          element: element,
          screenshot: screenshot,
          logs: logs ?? []
        )
        self?.finishSending(text: Strings.sent, error: false, close: true)
      } catch let error as FeedbackError {
        if error.keepsForLater {
          self?.finishSending(text: "\(error.message) \(Strings.savedForLater)", error: false, close: true)
        } else if error.wasFiled {
          self?.finishSending(text: error.message, error: false, close: true)
        } else {
          self?.finishSending(text: error.message, error: true, close: false)
        }
      } catch {
        self?.finishSending(text: error.localizedDescription, error: true, close: false)
      }
    }
  }

  private func finishSending(text: String, error: Bool, close: Bool) {
    isSending = false
    isModalInPresentation = !close
    setSendItem()
    show(text, error: error)
    if close {
      navigationItem.rightBarButtonItem?.isEnabled = false
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        self?.onFinish()
      }
    } else {
      refresh()
    }
  }

  // MARK: UIAdaptivePresentationControllerDelegate

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    logsTask?.cancel()
    FeedbackPresenter.shared.tearDown()
  }
}
#endif
