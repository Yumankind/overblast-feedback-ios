#if canImport(UIKit)
import UIKit

/// "Point at the problem": the frozen screenshot, full screen. A tap is turned into a point in the
/// app's window and the LIVE hierarchy under it is searched, so the element is the real view and
/// not a guess from pixels. The box drawn here is the box that will be drawn on the screenshot.
@MainActor
final class PointerViewController: UIViewController {
  private let image: UIImage
  private weak var appWindow: UIWindow?
  private let privateRects: [CGRect]
  private var selection: ElementPicker.Selection?
  private let onDone: (ElementPicker.Selection?) -> Void

  private let imageView = UIImageView()
  private let box = UIView()
  private let hint = UILabel()
  private let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private lazy var doneButton = UIButton(type: .system)

  init(image: UIImage, appWindow: UIWindow, privateRects: [CGRect], selection: ElementPicker.Selection?, onDone: @escaping (ElementPicker.Selection?) -> Void) {
    self.image = image
    self.appWindow = appWindow
    self.privateRects = privateRects
    self.selection = selection
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    imageView.image = image
    imageView.contentMode = .scaleToFill
    imageView.isUserInteractionEnabled = true
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = Strings.pointerImage
    imageView.accessibilityHint = Strings.pointerImageHint
    // Lets a VoiceOver user touch the picture directly, which is the only way to point at it.
    imageView.accessibilityTraits = [.image, .allowsDirectInteraction]
    imageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(imageView)

    box.isUserInteractionEnabled = false
    box.layer.borderColor = ScreenshotRenderer.highlightColor.cgColor
    box.layer.borderWidth = 3
    box.layer.cornerRadius = 4
    box.backgroundColor = ScreenshotRenderer.highlightColor.withAlphaComponent(0.15)
    box.isHidden = true
    imageView.addSubview(box)

    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.layer.cornerRadius = 14
    bar.clipsToBounds = true
    view.addSubview(bar)

    hint.font = .preferredFont(forTextStyle: .subheadline)
    hint.adjustsFontForContentSizeCategory = true
    hint.numberOfLines = 0
    hint.textColor = .label
    hint.text = Strings.pointerHint

    let cancel = UIButton(type: .system)
    cancel.setTitle(Strings.cancel, for: .normal)
    cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
    cancel.titleLabel?.adjustsFontForContentSizeCategory = true
    cancel.addAction(UIAction { [weak self] _ in self?.finish(keep: false) }, for: .primaryActionTriggered)

    doneButton.setTitle(Strings.done, for: .normal)
    doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
    doneButton.addAction(UIAction { [weak self] _ in self?.finish(keep: true) }, for: .primaryActionTriggered)

    let row = UIStackView(arrangedSubviews: [cancel, hint, doneButton])
    row.axis = .horizontal
    row.spacing = 12
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
    hint.textAlignment = .center
    bar.contentView.addSubview(row)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: view.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

      row.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -14),
      row.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -10),
    ])

    imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    updateSelectionUI()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateSelectionUI()
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    guard let appWindow, let ownWindow = view.window else { return }
    let inOwnWindow = gesture.location(in: nil)
    let point = appWindow.convert(inOwnWindow, from: ownWindow)
    selection = ElementPicker.select(at: point, in: appWindow, privateRects: privateRects)
    updateSelectionUI()
    if let selection {
      UIAccessibility.post(notification: .announcement, argument: Strings.selected(selection.element))
    }
  }

  private func updateSelectionUI() {
    doneButton.isEnabled = selection != nil
    guard let selection, let appWindow, let ownWindow = view.window else {
      box.isHidden = true
      hint.text = Strings.pointerHint
      return
    }
    let inOwnWindow = ownWindow.convert(selection.frame, from: appWindow)
    box.frame = imageView.convert(inOwnWindow, from: nil).insetBy(dx: -2, dy: -2)
    box.isHidden = false
    hint.text = Strings.selected(selection.element)
  }

  /// Done hands the selection back; Cancel leaves whatever the sheet had before.
  private func finish(keep: Bool) {
    let result = selection
    dismiss(animated: true) { [onDone] in
      if keep { onDone(result) }
    }
  }
}
#endif
