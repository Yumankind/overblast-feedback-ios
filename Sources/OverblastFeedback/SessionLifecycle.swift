#if canImport(UIKit) || os(macOS)
@_spi(OverblastPlatform) import OverblastFeedbackCore
import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The UI half of contract §3.4: it opens the session at `start`, closes it when the app goes to the
/// background (iOS, iPadOS, visionOS) or terminates (all three, and macOS, where an app in the
/// background is still running), listens to MetricKit, and makes the offer after an unexpected end.
@MainActor
enum SessionLifecycle {
  private static var observers: [NSObjectProtocol] = []
  private static var started = false

  static func start(options: FeedbackOptions) {
    guard !started else { return }
    started = true
    let previous = OverblastFeedback.beginSession()
    let center = NotificationCenter.default
    #if canImport(UIKit)
    let closing: [Notification.Name] = [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
    let opening: [Notification.Name] = [UIApplication.willEnterForegroundNotification]
    #else
    let closing: [Notification.Name] = [NSApplication.willTerminateNotification]
    let opening: [Notification.Name] = []
    #endif
    for name in closing {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in OverblastFeedback.closeSession() })
    }
    for name in opening {
      observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in OverblastFeedback.reopenSession() })
    }
    MetricKitListener.start()
    if previous != nil, options.offerReportAfterCrash {
      scheduleOffer(attempt: 0)
    }
  }

  /// The offer waits for the app to have a window on screen and to be in front, and gives up after
  /// half a minute of trying (the previous session stays available to `previousSession`).
  private static func scheduleOffer(attempt: Int) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: attempt == 0 ? 1_500_000_000 : 1_000_000_000)
      guard OverblastFeedback.previousSession != nil else { return }
      if CrashOffer.canShow() {
        CrashOffer.show()
      } else if attempt < 30 {
        scheduleOffer(attempt: attempt + 1)
      }
    }
  }
}

/// MetricKit's crash diagnostics, kept for the report about the session they describe. They arrive
/// at a later launch than the crash, often the next one, sometimes a day later.
enum MetricKitListener {
  @MainActor
  static func start() {
    #if canImport(MetricKit)
    if #available(iOS 14.0, macOS 12.0, visionOS 1.0, *) {
      MXMetricManager.shared.add(MetricKitSubscriber.shared)
      MetricKitSubscriber.shared.handle(MXMetricManager.shared.pastDiagnosticPayloads)
    }
    #endif
  }
}

#if canImport(MetricKit)
@available(iOS 14.0, macOS 12.0, visionOS 1.0, *)
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
  static let shared = MetricKitSubscriber()

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    handle(payloads)
  }

  func handle(_ payloads: [MXDiagnosticPayload]) {
    var newest: MetricCrashRecord?
    for payload in payloads {
      for crash in payload.crashDiagnostics ?? [] {
        let record = Self.record(crash, begin: payload.timeStampBegin, end: payload.timeStampEnd)
        if newest.map({ record.end >= $0.end }) ?? true { newest = record }
      }
    }
    if let newest { OverblastFeedback.recordMetricCrash(newest) }
  }

  static func record(_ crash: MXCrashDiagnostic, begin: Date, end: Date) -> MetricCrashRecord {
    var name: String?
    var reason: String?
    if #available(iOS 17.0, macOS 14.0, *), let objc = crash.exceptionReason {
      name = objc.exceptionName
      reason = objc.composedMessage
    }
    let message = MetricKitSummary.message(
      exceptionType: crash.exceptionType?.intValue,
      signal: crash.signal?.intValue,
      terminationReason: crash.terminationReason,
      exceptionName: name,
      exceptionReason: reason
    )
    let stack = MetricKitSummary.stack(fromCallStackTree: crash.callStackTree.jsonRepresentation())
    return MetricCrashRecord(begin: begin, end: end, message: message, stack: stack)
  }
}
#endif
#endif
