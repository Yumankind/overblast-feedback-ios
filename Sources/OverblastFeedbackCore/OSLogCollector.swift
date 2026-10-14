import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Reads the app's own unified log for the last few minutes.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` is the only scope an app may open on iOS, and it
/// sees what THIS process logged through `Logger`, `os_log` and `NSLog` since it started. It does not
/// see `print` (which goes to stdout, not the unified log), other processes, or anything before the
/// launch. Opening it can take a second on a busy device, so it is only ever called off the main
/// thread, when a report is being made, and its failure is silent: the in-memory buffer still goes.
public enum OSLogCollector {
  /// At most `limit` entries from the last `window` seconds, oldest first, `src: "oslog"`.
  public static func recent(window: TimeInterval = 300, limit: Int = FeedbackLimits.logEntries) -> [FeedbackLogEntry] {
    #if canImport(OSLog)
    guard #available(iOS 15.0, macOS 12.0, *) else { return [] }
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let position = store.position(date: Date().addingTimeInterval(-window))
      var out: [FeedbackLogEntry] = []
      for case let entry as OSLogEntryLog in try store.getEntries(at: position) {
        out.append(FeedbackLogEntry(
          t: Int64((entry.date.timeIntervalSince1970 * 1000).rounded()),
          level: level(entry.level),
          // A cheap cut here keeps a pathological line from costing memory; the real limit is
          // applied, with the redaction, when the report is built.
          msg: String(entry.composedMessage.prefix(FeedbackLimits.logMessage)),
          src: "oslog"
        ))
        if out.count > limit * 4 { out.removeFirst(out.count - limit) }
      }
      return Array(out.suffix(limit))
    } catch {
      return []
    }
    #else
    return []
    #endif
  }

  #if canImport(OSLog)
  @available(iOS 15.0, macOS 12.0, *)
  static func level(_ level: OSLogEntryLog.Level) -> FeedbackLogLevel {
    switch level {
    case .debug: return .debug
    case .info, .notice, .undefined: return .info
    case .error, .fault: return .error
    @unknown default: return .info
    }
  }
  #endif

  /// Two sources merged by time, newest `limit` kept, oldest first.
  public static func merge(_ a: [FeedbackLogEntry], _ b: [FeedbackLogEntry], limit: Int = FeedbackLimits.logEntries) -> [FeedbackLogEntry] {
    Array((a + b).sorted { $0.t < $1.t }.suffix(limit))
  }
}
