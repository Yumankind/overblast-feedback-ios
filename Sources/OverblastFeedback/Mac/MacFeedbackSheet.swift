#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// This library's own sheet windows. Never "the app's window": the context, the capture and the
/// element picker all look past them.
final class FeedbackSheetWindow: NSWindow {}

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
  @Published var email = ""
  @Published private(set) var preview: NSImage?
  @Published private(set) var isSending = false
  @Published private(set) var isFinished = false
  @Published private(set) var status: Status?

  /// Started when the sheet opens, so the unified log (which can take a second to read) is ready by
  /// the time the person presses Send.
  private var logsTask: Task<[FeedbackLogEntry], Never>?

  var onPoint: () -> Void = {}
  var onFinish: () -> Void = {}

  /// What opened the sheet; `.relaunch` makes it a report about the previous session, with that
  /// session's saved logs and how it ended.
  let trigger: FeedbackTrigger
  /// The logs are collected up to here: what is logged about the sheet itself is not the app's.
  let openedAt = Date()
  var isAboutPreviousSession: Bool { trigger == .relaunch }

  init(capture: ScreenCapture, category: FeedbackCategory, message: String, trigger: FeedbackTrigger = .button) {
    self.capture = capture
    self.category = category
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

  private func updatePreview() {
    guard includeScreenshot else {
      preview = nil
      return
    }
    var image = capture.image
    if let selection {
      image = ScreenshotRenderer.highlighted(image, rect: selection.frame, size: capture.windowSize)
    }
    preview = ScreenshotRenderer.nsImage(image, size: capture.windowSize)
  }

  func point() { onPoint() }

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
    let screenshot = includeScreenshot ? ScreenshotRenderer.screenshot(from: capture, element: element) : nil
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
        _ = try await OverblastFeedback.report(
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
    if close, isAboutPreviousSession { OverblastFeedback.forgetPreviousSession() }
    isSending = false
    isFinished = close
    status = Status(text: text, isError: error)
    Announce.say(text)
    if close {
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        self?.onFinish()
      }
    }
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

/// The sheet itself, in system fonts and colours, so Dynamic Type's Mac equivalent (the text size
/// setting), dark mode and VoiceOver come with it.
struct FeedbackSheetView: View {
  @ObservedObject var model: FeedbackSheetModel
  @FocusState private var messageFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(Strings.title)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      Picker(Strings.category, selection: $model.category) {
        ForEach(Strings.categories, id: \.0) { item in
          Text(item.1).tag(item.0)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel(Strings.category)

      message

      element

      // The key's owner can switch screenshots off (contract §2.1); then none is offered.
      if OverblastFeedback.effectiveConfig.screenshots {
        screenshot
      }

      if model.asksForEmail {
        VStack(alignment: .leading, spacing: 4) {
          TextField(Strings.emailPlaceholder, text: $model.email)
            .textFieldStyle(.roundedBorder)
            .accessibilityHint(Strings.emailFootnote)
          Text(Strings.emailFootnote)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }

      Text(model.willSend)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let status = model.status {
        Text(status.text)
          .foregroundStyle(status.isError ? Color.red : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Spacer()
        if model.isSending {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(Strings.sending)
          Text(Strings.sending)
            .foregroundStyle(.secondary)
        }
        Button(Strings.cancel, role: .cancel) { model.cancel() }
          .keyboardShortcut(.cancelAction)
          .disabled(model.isSending || model.isFinished)
        Button(Strings.send) { model.send() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSend)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      if model.message.isEmpty { messageFocused = true }
    }
  }

  private var message: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $model.message)
        .font(.body)
        .focused($messageFocused)
        .disabled(model.isSending || model.isFinished)
        .accessibilityLabel(Strings.messageLabel)
        .accessibilityHint(Strings.messagePlaceholder)
      if model.message.isEmpty {
        Text(model.isAboutPreviousSession ? Strings.crashPlaceholder : Strings.messagePlaceholder)
          .font(.body)
          .foregroundStyle(.tertiary)
          .padding(.leading, 5)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: 110, maxHeight: 200)
    .padding(6)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
  }

  private var element: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        model.point()
      } label: {
        Label(model.selection == nil ? Strings.point : Strings.pointAgain, systemImage: "hand.point.up.left")
      }
      .disabled(model.isSending || model.isFinished)
      if let selection = model.selection {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(Strings.selected(selection.element))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Button(Strings.clearSelection) { model.selection = nil }
            .buttonStyle(.link)
            .font(.footnote)
            .accessibilityLabel(Strings.clearSelectionHint)
            .disabled(model.isSending || model.isFinished)
        }
      }
    }
  }

  private var screenshot: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(Strings.includeScreenshot, isOn: $model.includeScreenshot)
        .toggleStyle(.switch)
        .disabled(model.isSending || model.isFinished)
      if model.includeScreenshot, let preview = model.preview {
        VStack(spacing: 4) {
          Image(nsImage: preview)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .accessibilityLabel(Strings.screenshotPreview)
          Button(Strings.remove) { model.includeScreenshot = false }
            .font(.footnote)
            .accessibilityLabel(Strings.removeScreenshotHint)
            .disabled(model.isSending || model.isFinished)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}
#endif
