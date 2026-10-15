#if canImport(UIKit)
import UIKit

/// "Point at the problem": the frozen screenshot, full screen, with one line at the top saying what
/// to do. A tap is turned into a point in the app's window and the LIVE hierarchy under it is
/// searched, so the element is the real view and not a guess from pixels. The pick is shown with a
/// clear box and its name, and nothing is taken until the person confirms with "Use this"; the box
/// drawn here is the box drawn on the screenshot.
@MainActor
final class PointerViewController: UIViewController {
  private let image: UIImage
  private weak var appWindow: UIWindow?
  private let privateRects: [CGRect]
  var selection: ElementPicker.Selection?
  private let onDone: (ElementPicker.Selection?) -> Void

  private let imageView = UIImageView()
  private let dim = UIView()
  private let box = UIView()
  private let hintBar = PointerViewController.material()
  private let hint = UILabel()
  private let bar = PointerViewController.material()
  private let pickedLabel = UILabel()
  private let useButton = UIButton(type: .system)

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

  /// The bars' background: the system material (glass on Vision Pro).
  static func material() -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    #if !os(visionOS)
    // Under the material, so the bars read on any screenshot even where the blur is flattened.
    view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
    #endif
    return view
  }

  private var accent: UIColor { ThemeUI.accent(appWindow) }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    view.tintColor = accent

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

    // Everything but the pick dims a little, so the pick stands out on any screenshot.
    dim.isUserInteractionEnabled = false
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    dim.isHidden = true
    imageView.addSubview(dim)

    box.isUserInteractionEnabled = false
    box.layer.borderColor = accent.cgColor
    box.layer.borderWidth = 3
    box.layer.cornerRadius = min(ThemeUI.radius, 8)
    box.layer.cornerCurve = .continuous
    box.layer.shadowColor = accent.cgColor
    box.layer.shadowOpacity = 0.6
    box.layer.shadowRadius = 8
    box.layer.shadowOffset = .zero
    box.backgroundColor = accent.withAlphaComponent(0.12)
    box.isHidden = true
    imageView.addSubview(box)

    // The one line at the top: what to do.
    hint.font = ThemeUI.font(.subheadline, weight: .semibold)
    hint.adjustsFontForContentSizeCategory = true
    hint.numberOfLines = 0
    hint.textAlignment = .center
    hint.text = Strings.pointerHint
    hint.translatesAutoresizingMaskIntoConstraints = false
    hintBar.clipsToBounds = true
    hintBar.layer.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 40)
    hintBar.layer.cornerCurve = .continuous
    hintBar.translatesAutoresizingMaskIntoConstraints = false
    hintBar.contentView.addSubview(hint)
    view.addSubview(hintBar)

    // The bottom bar: Cancel, what is picked, Use this.
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.layer.cornerRadius = max(14, ThemeUI.radius + 2)
    bar.layer.cornerCurve = .continuous
    bar.clipsToBounds = true
    view.addSubview(bar)

    var cancelConfig = UIButton.Configuration.plain()
    cancelConfig.title = Strings.cancel
    cancelConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.body)
      return a
    }
    let cancel = UIButton(configuration: cancelConfig, primaryAction: UIAction { [weak self] _ in self?.finish(keep: false) })

    pickedLabel.font = ThemeUI.font(.subheadline)
    pickedLabel.adjustsFontForContentSizeCategory = true
    pickedLabel.numberOfLines = 2
    pickedLabel.textAlignment = .center
    pickedLabel.textColor = .secondaryLabel
    pickedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    pickedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    useButton.addAction(UIAction { [weak self] _ in self?.finish(keep: true) }, for: .primaryActionTriggered)
    styleUseButton()

    let row = UIStackView(arrangedSubviews: [cancel, pickedLabel, useButton])
    row.axis = .horizontal
    row.spacing = 10
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(row)

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: view.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      dim.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      dim.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      dim.topAnchor.constraint(equalTo: imageView.topAnchor),
      dim.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

      hintBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
      hintBar.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
      hintBar.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16),
      hintBar.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -16),
      hint.leadingAnchor.constraint(equalTo: hintBar.contentView.leadingAnchor, constant: 18),
      hint.trailingAnchor.constraint(equalTo: hintBar.contentView.trailingAnchor, constant: -18),
      hint.topAnchor.constraint(equalTo: hintBar.contentView.topAnchor, constant: 10),
      hint.bottomAnchor.constraint(equalTo: hintBar.contentView.bottomAnchor, constant: -10),

      bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
      bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
      bar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
      row.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -8),
      row.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -8),
      useButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])

    imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    updateSelectionUI()
  }

  private func styleUseButton() {
    var config = UIButton.Configuration.filled()
    config.title = Strings.useThis
    config.baseBackgroundColor = accent
    config.baseForegroundColor = ThemeUI.onAccent(appWindow)
    config.background.cornerRadius = ThemeUI.theme.cornerRadius(forHeight: 44)
    config.cornerStyle = .fixed
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = ThemeUI.font(.body, weight: .semibold)
      return a
    }
    useButton.configuration = config
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let room = view.safeAreaLayoutGuide.layoutFrame.width - 32 - 36
    if abs(hint.preferredMaxLayoutWidth - BalancedWrap.width(singleLine: ThemeUI.singleLineWidth(hint.text ?? "", font: hint.font), available: room)) > 0.5 {
      hint.balance(within: room)
    }
    updateSelectionUI()
  }

  @objc private func tapped(_ gesture: UITapGestureRecognizer) {
    guard let appWindow, let ownWindow = view.window else { return }
    let inOwnWindow = gesture.location(in: nil)
    let point = appWindow.convert(inOwnWindow, from: ownWindow)
    selection = ElementPicker.select(at: point, in: appWindow, privateRects: privateRects)
    updateSelectionUI()
    if let selection {
      #if !os(visionOS)
      UISelectionFeedbackGenerator().selectionChanged()
      #endif
      UIAccessibility.post(notification: .announcement, argument: Strings.selected(selection.element))
    }
  }

  func updateSelectionUI() {
    useButton.isEnabled = selection != nil
    guard let selection, let appWindow, let ownWindow = view.window else {
      box.isHidden = true
      dim.isHidden = true
      dim.layer.mask = nil
      pickedLabel.text = nil
      return
    }
    let inOwnWindow = ownWindow.convert(selection.frame, from: appWindow)
    let frame = imageView.convert(inOwnWindow, from: nil).insetBy(dx: -3, dy: -3)
    box.frame = frame
    box.isHidden = false
    // The dim with a hole where the pick is.
    let path = UIBezierPath(rect: imageView.bounds)
    path.append(UIBezierPath(roundedRect: frame, cornerRadius: box.layer.cornerRadius))
    let mask = CAShapeLayer()
    mask.path = path.cgPath
    mask.fillRule = .evenOdd
    dim.layer.mask = mask
    dim.isHidden = false
    pickedLabel.text = Strings.selected(selection.element)
  }

  /// "Use this" hands the selection back; Cancel leaves whatever the sheet had before.
  private func finish(keep: Bool) {
    let result = selection
    dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [onDone] in
      if keep { onDone(result) }
    }
  }
}
#endif
