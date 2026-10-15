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
///
/// WHAT IS KEPT: only the app's own lines. A sheet session alone makes UIKit and RunningBoard write
/// hundreds of debug lines into this same store ("Sending UIEvent type…", input-view placement,
/// process assertions), and the newest 500 would otherwise be nothing else. So a line is kept when it
/// is at `info`, `notice`, `error` or `fault` (never `debug`), and its subsystem is empty (`NSLog`,
/// `os_log` with the default log) or is not Apple's own (`com.apple.*`), and it was written before
/// the sheet opened. The newest 500 are taken AFTER that filter.
public enum OSLogCollector {
  /// A unified-log line as the filter sees it; `OSLogEntryLog` turned into plain values so the filter
  /// can be tested without a log store.
  public struct Line: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case undefined, debug, info, notice, error, fault }
    public var date: Date
    public var level: Level
    /// Empty for `NSLog` and the default log.
    public var subsystem: String
    public var message: String

    public init(date: Date, level: Level, subsystem: String = "", message: String) {
      self.date = date
      self.level = level
      self.subsystem = subsystem
      self.message = message
    }
  }

  /// True for a line the app wrote itself, at a level worth a person's attention.
  public static func isAppLine(_ line: Line) -> Bool {
    switch line.level {
    case .info, .notice, .error, .fault: break
    case .debug, .undefined: return false
    }
    return !(line.subsystem == "com.apple" || line.subsystem.hasPrefix("com.apple."))
  }

  /// The app's own lines from `lines` written before `until` (nil: all of them), the newest `limit`,
  /// oldest first, `src: "oslog"`. Streams: never holds more than a few times `limit`.
  public static func select(_ lines: some Sequence<Line>, until: Date? = nil, limit: Int = FeedbackLimits.logEntries) -> [FeedbackLogEntry] {
    var out: [FeedbackLogEntry] = []
    for line in lines {
      if let until, line.date >= until { continue }
      guard isAppLine(line) else { continue }
      out.append(FeedbackLogEntry(
        t: Int64((line.date.timeIntervalSince1970 * 1000).rounded()),
        level: level(line.level),
        // A cheap cut here keeps a pathological line from costing memory; the real limit is
        // applied, with the redaction, when the report is built.
        msg: String(line.message.prefix(FeedbackLimits.logMessage)),
        src: "oslog"
      ))
      if out.count > limit * 4 { out.removeFirst(out.count - limit) }
    }
    return Array(out.suffix(limit))
  }

  static func level(_ level: Line.Level) -> FeedbackLogLevel {
    switch level {
    case .debug: return .debug
    case .info, .notice, .undefined: return .info
    case .error, .fault: return .error
    }
  }

  /// At most `limit` of the app's own entries from the last `window` seconds and before `until`,
  /// oldest first, `src: "oslog"`.
  public static func recent(window: TimeInterval = 300, until: Date? = nil, limit: Int = FeedbackLimits.logEntries) -> [FeedbackLogEntry] {
    #if canImport(OSLog)
    guard #available(iOS 15.0, macOS 12.0, *) else { return [] }
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let position = store.position(date: (until ?? Date()).addingTimeInterval(-window))
      let lines = try store.getEntries(at: position).lazy.compactMap { $0 as? OSLogEntryLog }.map { entry in
        Line(date: entry.date, level: lineLevel(entry.level), subsystem: entry.subsystem, message: entry.composedMessage)
      }
      return select(lines, until: until, limit: limit)
    } catch {
      return []
    }
    #else
    return []
    #endif
  }

  #if canImport(OSLog)
  @available(iOS 15.0, macOS 12.0, *)
  static func lineLevel(_ level: OSLogEntryLog.Level) -> Line.Level {
    switch level {
    case .debug: return .debug
    case .info: return .info
    case .notice: return .notice
    case .error: return .error
    case .fault: return .fault
    case .undefined: return .undefined
    @unknown default: return .undefined
    }
  }
  #endif

  /// Two sources merged by time, newest `limit` kept, oldest first.
  public static func merge(_ a: [FeedbackLogEntry], _ b: [FeedbackLogEntry], limit: Int = FeedbackLimits.logEntries) -> [FeedbackLogEntry] {
    Array((a + b).sorted { $0.t < $1.t }.suffix(limit))
  }
}
