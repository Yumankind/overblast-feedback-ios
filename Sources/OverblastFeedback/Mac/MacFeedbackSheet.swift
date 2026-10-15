#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// This library's own sheet and panel windows (an `NSPanel`, so the short-window fallback can float
/// beside the app's window). Never "the app's window": the context, the capture and the element
/// picker all look past them.
final class FeedbackSheetWindow: NSPanel {}

/// The report sheet's state: message, category, the element, the screenshot (off until the person
/// turns it on), an email when the app did not supply one, and the send.
@MainActor
final class FeedbackSheetModel: ObservableObject {
  struct Status: Equatable {
    let text: String
    let isError: Bool
  }

  let capture: ScreenCapture
  let asksForEmail: Bool

  @Published var category: FeedbackCategory
  @Published var message: String
  @Published var selection: ElementPicker.Selection? { didSet { updatePreview() } }
  @Published var includeScreenshot = false { didSet { updatePreview() } }
  /// The reporter's covers and blurs on the screenshot.
  @Published var edits: [ScreenshotEdit] = [] { didSet { updatePreview() } }
  @Published var email = ""
  @Published private(set) var preview: NSImage?
  /// The picked part of the frozen picture, with its box.
  @Published private(set) var pickImage: NSImage?
  /// After Send: the checkmark (or clock) and the sentence, for a moment before the sheet goes.
  @Published private(set) var confirmation: (symbol: String, text: String)?
  /// The tallest the form may be: the room under the window's content (or the panel's height). The
  /// form scrolls inside it and Cancel and Send stay pinned below.
  @Published var maxHeight: CGFloat = 640
  /// In a panel the form fills the panel's height rather than fitting its content.
  @Published var fillsHeight = false
  @Published private(set) var isSending = false
  @Published private(set) var isFinished = false
  @Published private(set) var status: Status?

  /// Started when the sheet opens, so the unified log (which can take a second to read) is ready by
  /// the time the person presses Send.
  private var logsTask: Task<[FeedbackLogEntry], Never>?

  var onPoint: () -> Void = {}
  var onEdit: () -> Void = {}
  var onFinish: () -> Void = {}

  /// What opened the sheet; `.relaunch` makes it a report about the previous session, with that
  /// session's saved logs and how it ended.
  let trigger: FeedbackTrigger
  /// The logs are collected up to here: what is logged about the sheet itself is not the app's.
  let openedAt = Date()
  var isAboutPreviousSession: Bool { trigger == .relaunch }

  /// The categories the key takes (contract §2): one means no choice at all.
  let categories: [(FeedbackCategory, String)]
  let title: String

  init(capture: ScreenCapture, category: FeedbackCategory?, message: String, trigger: FeedbackTrigger = .button) {
    let config = OverblastFeedback.effectiveConfig
    self.capture = capture
    self.category = config.category(for: category)
    self.categories = Strings.categories(for: config)
    self.title = Strings.title(for: config)
    self.message = message
    self.trigger = trigger
    self.asksForEmail = OverblastFeedback.reporter?.email == nil
    let openedAt = self.openedAt
    if trigger == .relaunch {
      let saved = OverblastFeedback.previousSession?.logs ?? []
      logsTask = Task { saved }
    } else {
      logsTask = Task.detached(priority: .utility) { await OverblastFeedback.collectLogs(until: openedAt) }
    }
  }

  var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

  var typedEmail: String? {
    guard asksForEmail else { return nil }
    let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
    return e.isEmpty ? nil : e
  }

  var canSend: Bool { !trimmedMessage.isEmpty && !isSending && !isFinished }

  var willSend: String {
    Strings.willSend(
      element: selection != nil,
      screenshot: includeScreenshot,
      logs: OverblastFeedback.options.includeLogs,
      email: typedEmail != nil || OverblastFeedback.reporter?.email != nil,
      crash: isAboutPreviousSession
    )
  }

  /// The frozen picture with the reporter's covers and blurs (the masks stay on top).
  var editedCapture: ScreenCapture {
    guard !edits.isEmpty else { return capture }
    let image = ScreenshotRedaction.apply(edits, to: capture.image, pointSize: capture.windowSize, masks: capture.privateRects, maskGray: ScreenCapture.maskGray)
    return ScreenCapture(image: image, windowSize: capture.windowSize, privateRects: capture.privateRects)
  }

  private func updatePreview() {
    let edited = editedCapture
    let accent = ThemeUI.accent()
    if let selection {
      let boxed = ScreenshotRenderer.highlighted(edited.image, rect: selection.frame, size: capture.windowSize, color: accent)
      let crop = PickThumbnail.cropRect(for: selection.frame, in: capture.windowSize)
      let scale = CGFloat(boxed.width) / max(capture.windowSize.width, 1)
      let pixels = PickThumbnail.pixelRect(crop, scale: scale, pixelSize: CGSize(width: boxed.width, height: boxed.height))
      pickImage = boxed.cropping(to: pixels).map { NSImage(cgImage: $0, size: crop.size) }
    } else {
      pickImage = nil
    }
    guard includeScreenshot else {
      preview = nil
      return
    }
    var image = edited.image
    if let selection {
      image = ScreenshotRenderer.highlighted(image, rect: selection.frame, size: capture.windowSize, color: accent)
    }
    preview = ScreenshotRenderer.nsImage(image, size: capture.windowSize)
  }

  func point() { onPoint() }
  func edit() { onEdit() }

  func cancel() {
    logsTask?.cancel()
    // The offer is made once: cancelling the report about the previous session is an answer too.
    if isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    onFinish()
  }

  func send() {
    guard canSend else { return }
    isSending = true
    status = nil

    let element = selection?.element
    let screenshot = includeScreenshot ? ScreenshotRenderer.screenshot(from: editedCapture, element: element, color: ThemeUI.accent()) : nil
    let messages = OverblastFeedback.options.messages
    let reporter = typedEmail.map { FeedbackReporter(email: $0) }
    let message = self.message
    let category = self.category
    let logsTask = self.logsTask
    let trigger = self.trigger
    let openedAt = self.openedAt
    // Decided at Send, so a MetricKit diagnostic that arrived while the person typed is in it.
    let crash = isAboutPreviousSession ? OverblastFeedback.previousSessionCrash : nil

    Task { @MainActor [weak self] in
      let logs = await logsTask?.value
      do {
        let receipt = try await OverblastFeedback.report(
          message: message,
          category: category,
          reporter: reporter,
          element: element,
          screenshot: screenshot,
          logs: logs ?? [],
          trigger: trigger,
          openedAt: openedAt,
          crash: crash
        )
        self?.finishSending(text: messages.thankYou(for: receipt), error: false, close: true, symbol: "checkmark.circle.fill")
      } catch let error as FeedbackError {
        if error.keepsForLater {
          self?.finishSending(text: "\(error.message) \(Strings.savedForLater)", error: false, close: true, symbol: "clock.arrow.circlepath")
        } else if error.wasFiled {
          self?.finishSending(text: error.message, error: false, close: true, symbol: "checkmark.circle.fill")
        } else {
          self?.finishSending(text: error.message, error: true, close: false)
        }
      } catch {
        self?.finishSending(text: error.localizedDescription, error: true, close: false)
      }
    }
  }

  private func finishSending(text: String, error: Bool, close: Bool, symbol: String? = nil) {
    if close, isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    isSending = false
    isFinished = close
    if close, let symbol {
      confirmation = (symbol, text)
    } else {
      status = Status(text: text, isError: error)
    }
    Announce.say(text)
    if close, symbol != nil {
      // Closes on Done or Esc, or by itself once the sentence has had time to be read; the pointer
      // over it, or VoiceOver on Done, holds it.
      confirmationTimer = ConfirmationTimer(text: text, startedAt: Date())
      Task { @MainActor [weak self] in
        while let self, self.confirmationTimer?.closedBy == nil {
          if self.confirmationTimer?.tick(at: Date()) == true {
            self.onFinish()
            return
          }
          try? await Task.sleep(nanoseconds: 200_000_000)
        }
      }
    }
  }

  /// The confirmation's clock.
  private(set) var confirmationTimer: ConfirmationTimer?

  /// Done or Esc: closes now, once.
  func closeConfirmation(_ reason: ConfirmationTimer.CloseReason) {
    guard confirmationTimer?.close(reason) == true else { return }
    onFinish()
  }

  func holdConfirmation(_ hold: ConfirmationTimer.Hold, _ on: Bool) {
    if on { confirmationTimer?.hold(hold, at: Date()) } else { confirmationTimer?.release(hold, at: Date()) }
  }
}

@MainActor
enum Announce {
  /// Read out by VoiceOver, as `UIAccessibility.post(.announcement)` is on iOS.
  static func say(_ text: String) {
    let element: Any = NSApplication.shared.mainWindow ?? NSApplication.shared
    NSAccessibility.post(
      element: element,
      notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
    )
  }
}

struct FieldsHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The sheet itself: the window-attached sheet a Mac app expects, in the theme's accent, font and
/// radius; the text size setting, dark mode and VoiceOver come with SwiftUI.
struct FeedbackSheetView: View {
  @ObservedObject var model: FeedbackSheetModel
  @FocusState private var messageFocused: Bool
  @AccessibilityFocusState private var doneFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var radius: CGFloat { ThemeUI.radius }
  private var busy: Bool { model.isSending || model.isFinished }

  /// The height of the fields, measured, so the sheet is as tall as they need and no taller than
  /// the room there is.
  @State private var fieldsHeight: CGFloat = 0
  static let barHeight: CGFloat = 58

  var body: some View {
    ZStack {
      if model.confirmation == nil {
        form
      }
      // The sheet shrinks to the confirmation (it is sized to its content), rather than leaving a
      // blank form-sized sheet behind the checkmark.
      if let confirmation = model.confirmation {
        VStack(spacing: 12) {
          Image(systemName: confirmation.symbol)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(ThemeUI.accentColor)
            .accessibilityHidden(true)
          Text(confirmation.text)
            .font(ThemeUI.swiftUIFont(.title3, weight: .semibold))
            .multilineTextAlignment(.center)
            // Two even lines rather than a full one and a lonely word.
            .frame(maxWidth: ThemeUI.balancedWidth(confirmation.text, style: .title3, bold: true, available: 480 - 64))
            .fixedSize(horizontal: false, vertical: true)
          Button(Strings.done) { model.closeConfirmation(.done) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityFocused($doneFocused)
            .padding(.top, 8)
          // Esc closes it too.
          Button("") { model.closeConfirmation(.escape) }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 180)
        .onHover { model.holdConfirmation(.hover, $0) }
        .onChange(of: doneFocused) { model.holdConfirmation(.voiceOverFocus, $0) }
        .onAppear {
          // The sentence is announced (by the model); then VoiceOver's focus goes to Done.
          Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            doneFocused = true
          }
        }
        .transition(reduceMotion ? .identity : .scale(scale: 0.85).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: model.confirmation?.text)
    .tint(ThemeUI.accentColor)
    .frame(width: 480)
  }

  /// The fields scroll; the bar with Cancel and Send is pinned under them, always visible.
  private var form: some View {
    VStack(spacing: 0) {
      ScrollView(.vertical) {
        fields
          .background(GeometryReader { geo in
            Color.clear.preference(key: FieldsHeightKey.self, value: geo.size.height)
          })
      }
      .frame(height: model.fillsHeight ? nil : min(max(fieldsHeight, 160), max(160, model.maxHeight - Self.barHeight)))
      .frame(maxHeight: model.fillsHeight ? .infinity : nil)
      .onPreferenceChange(FieldsHeightKey.self) { height in
        MainActor.assumeIsolated { fieldsHeight = height }
      }
      Divider()
      bar
        .frame(height: Self.barHeight)
    }
  }

  private var bar: some View {
    HStack(spacing: 10) {
      Spacer()
      Button(Strings.cancel, role: .cancel) { model.cancel() }
        .keyboardShortcut(.cancelAction)
        .disabled(busy)
      Button {
        model.send()
      } label: {
        HStack(spacing: 6) {
          if model.isSending {
            ProgressView().controlSize(.small)
          }
          Text(model.isSending ? Strings.sending : Strings.send)
        }
        .frame(minWidth: 72)
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(!model.canSend)
    }
    .font(ThemeUI.swiftUIFont(.body))
    .padding(.horizontal, 22)
  }

  private var fields: some View {
    VStack(alignment: .leading, spacing: 16) {
      // A panel says the title in its own title bar.
      if !model.fillsHeight {
        Text(model.title)
          .font(ThemeUI.swiftUIFont(.title3, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
      }

      if model.categories.count > 1 {
        Picker(Strings.category, selection: $model.category) {
          ForEach(model.categories, id: \.0) { item in
            Text(item.1).tag(item.0)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Strings.category)
        .disabled(busy)
      }

      message

      element

      // The key's owner can switch screenshots off (contract §2.1); then none is offered.
      if OverblastFeedback.effectiveConfig.screenshots {
        screenshot
      }

      if model.asksForEmail {
        VStack(alignment: .leading, spacing: 4) {
          TextField(Strings.emailPlaceholder, text: $model.email)
            .textFieldStyle(.plain)
            .font(ThemeUI.swiftUIFont(.body))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: min(radius, 10)).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: min(radius, 10)).stroke(Color(nsColor: .separatorColor)))
            .accessibilityHint(Strings.emailFootnote)
            .disabled(busy)
          Text(Strings.emailFootnote)
            .font(ThemeUI.swiftUIFont(.footnote))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }

      Text(model.willSend)
        .font(ThemeUI.swiftUIFont(.footnote))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let status = model.status {
        Text(status.text)
          .font(ThemeUI.swiftUIFont(.callout))
          .foregroundStyle(status.isError ? Color.red : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

    }
    .padding(22)
    .onAppear {
      if model.message.isEmpty { messageFocused = true }
    }
  }

  private var message: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $model.message)
        .font(ThemeUI.swiftUIFont(.body))
        .scrollContentBackground(.hidden)
        .focused($messageFocused)
        .disabled(busy)
        .accessibilityLabel(Strings.messageLabel)
        .accessibilityHint(Strings.messagePlaceholder)
      if model.message.isEmpty {
        Text(model.isAboutPreviousSession ? Strings.crashPlaceholder : Strings.messagePlaceholder)
          .font(ThemeUI.swiftUIFont(.body))
          .foregroundStyle(.tertiary)
          .padding(.leading, 5)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: min(130, max(70, model.maxHeight * 0.2)), maxHeight: 220)
    .padding(8)
    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(nsColor: .separatorColor)))
  }

  @ViewBuilder
  private var element: some View {
    if let selection = model.selection {
      // The pick: a thumbnail of that part of the window with its box, its name, Change and Remove.
      HStack(spacing: 12) {
        if let image = model.pickImage {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: min(radius, 8), style: .continuous))
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(Strings.selected(selection.element))
            .font(ThemeUI.swiftUIFont(.callout, weight: .medium))
            .lineLimit(2)
          HStack(spacing: 12) {
            Button(Strings.change) { model.point() }
              .accessibilityHint(Strings.pickChangeHint)
            Button(Strings.remove, role: .destructive) { model.selection = nil }
              .foregroundStyle(Color.red)
              .accessibilityHint(Strings.pickRemoveHint)
          }
          .buttonStyle(.plain)
          .foregroundStyle(ThemeUI.accentColor)
          .font(ThemeUI.swiftUIFont(.callout))
          .disabled(busy)
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
      .accessibilityElement(children: .contain)
    } else {
      Button {
        model.point()
      } label: {
        Label(Strings.point, systemImage: "hand.point.up.left")
          .font(ThemeUI.swiftUIFont(.body))
      }
      .disabled(busy)
    }
  }

  private var screenshot: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(Strings.includeScreenshot, isOn: $model.includeScreenshot)
        .toggleStyle(.switch)
        .font(ThemeUI.swiftUIFont(.body))
        .disabled(busy)
      if model.includeScreenshot, let preview = model.preview {
        VStack(alignment: .leading, spacing: 4) {
          // The preview opens the editor (cover or blur parts).
          Button { model.edit() } label: {
            Image(nsImage: preview)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(maxWidth: .infinity, maxHeight: min(180, max(90, model.maxHeight * 0.25)))
              .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(nsColor: .separatorColor)))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.edits.isEmpty ? Strings.screenshotPreview : Strings.screenshotEdited)
          .accessibilityHint(Strings.editScreenshotHint)
          HStack(spacing: 12) {
            Button(Strings.editScreenshot) { model.edit() }
              .accessibilityHint(Strings.editScreenshotHint)
            Button(Strings.remove, role: .destructive) { model.includeScreenshot = false }
              .foregroundStyle(Color.red)
              .accessibilityHint(Strings.removeScreenshotHint)
          }
          .buttonStyle(.plain)
          .foregroundStyle(ThemeUI.accentColor)
          .font(ThemeUI.swiftUIFont(.callout))
          .disabled(busy)
        }
      }
    }
  }
}
#endif
