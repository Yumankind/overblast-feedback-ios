import Foundation

// "What happened just before" (contract §3.4): the log buffer kept on disk as the app runs, a marker
// saying whether the last session ended cleanly, what the uncaught-exception handler and MetricKit
// said about how it ended, and the decision, at the next launch, of what `crash` to send.
//
// Everything here is Foundation and plain files, so it is tested on a Mac. The UI half closes and
// reopens the session on the app's lifecycle notifications, subscribes to MetricKit, and makes the
// offer.

/// One run of the app, from launch (or coming back to the foreground) until it goes to the
/// background or terminates cleanly.
public struct SessionMarker: Codable, Sendable, Equatable {
  public var id: String
  public var startedAt: Date
  /// The last time the library wrote anything for this session: about when it ended, if it never
  /// closed.
  public var lastSeenAt: Date
  public var closedAt: Date?

  public var isOpen: Bool { closedAt == nil }

  public init(id: String = UUID().uuidString, startedAt: Date, lastSeenAt: Date? = nil, closedAt: Date? = nil) {
    self.id = id
    self.startedAt = startedAt
    self.lastSeenAt = lastSeenAt ?? startedAt
    self.closedAt = closedAt
  }
}

/// What the uncaught-exception handler wrote on its way down.
public struct ExceptionRecord: Codable, Sendable, Equatable {
  public var sessionId: String
  public var at: Date
  public var name: String
  public var reason: String?
  public var stack: String?

  public init(sessionId: String, at: Date, name: String, reason: String?, stack: String?) {
    self.sessionId = sessionId
    self.at = at
    self.name = name
    self.reason = reason
    self.stack = stack
  }
}

/// The newest `MXCrashDiagnostic`, summarised, with the window its payload covers.
public struct MetricCrashRecord: Codable, Sendable, Equatable {
  public var begin: Date
  public var end: Date
  public var message: String
  public var stack: String?

  public init(begin: Date, end: Date, message: String, stack: String?) {
    self.begin = begin
    self.end = end
    self.message = message
    self.stack = stack
  }
}

/// The session before this one, when it never closed: its saved logs and what is known about its end.
public struct PreviousSession: Codable, Sendable, Equatable {
  public var marker: SessionMarker
  public var logs: [FeedbackLogEntry]
  public var exception: ExceptionRecord?

  public init(marker: SessionMarker, logs: [FeedbackLogEntry], exception: ExceptionRecord?) {
    self.marker = marker
    self.logs = logs
    self.exception = exception
  }
}

/// Decides the `crash` a report about the previous session carries. Pure, so it is tested alone.
public enum CrashDecision {
  /// A MetricKit payload covers a window of time (often a day); it belongs to a session when that
  /// window overlaps the session's life, give or take a minute for clocks and for the crash itself
  /// coming after the last write.
  public static func matches(_ metric: MetricCrashRecord, _ marker: SessionMarker, slack: TimeInterval = 60) -> Bool {
    metric.begin <= marker.lastSeenAt.addingTimeInterval(slack) && metric.end >= marker.startedAt.addingTimeInterval(-slack)
  }

  /// The handler's exception when the session wrote one; else MetricKit's crash when it matches the
  /// session by time; else `unknown` from the marker alone (often the system ending the app for
  /// memory or a watchdog, which leaves no trace an app can read).
  public static func crash(for previous: PreviousSession, metric: MetricCrashRecord?) -> FeedbackCrash {
    if let e = previous.exception, e.sessionId == previous.marker.id {
      let message = e.reason.map { "\(e.name): \($0)" } ?? e.name
      return FeedbackCrash(kind: .exception, at: millis(e.at), message: message, stack: e.stack, source: .handler)
    }
    if let metric, matches(metric, previous.marker) {
      return FeedbackCrash(kind: .crash, at: millis(previous.marker.lastSeenAt), message: metric.message, stack: metric.stack, source: .metrickit)
    }
    return FeedbackCrash(kind: .unknown, at: millis(previous.marker.lastSeenAt), source: .marker)
  }

  static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// The log buffer's copy on disk: NDJSON in two rotating files, `log-<n>.ndjson` and
/// `log-<n-1>.ndjson`, at most `maxBytes` in all. When the newer file reaches half the budget the
/// older one is deleted and a new one begun. Each line is `{"s": seq, "e": entry}`; a repeat counted
/// after its line was written writes the line again, and the reader keeps the last copy of each `s`.
///
/// Generations are numbered in the names, so which file is newer never depends on file dates (whose
/// reading is a "required reason" API on Apple's platforms).
final class LogDisk {
  struct Line: Codable {
    var s: Int64
    var e: FeedbackLogEntry
  }

  let directory: URL
  let maxBytes: Int
  private var generation: Int
  private var currentSize: Int

  init(directory: URL, maxBytes: Int = 4_000_000) {
    self.directory = directory
    self.maxBytes = maxBytes
    let gens = LogDisk.generations(in: directory)
    generation = gens.last ?? 0
    currentSize = (try? Data(contentsOf: LogDisk.url(directory, generation)).count) ?? 0
  }

  static func url(_ directory: URL, _ generation: Int) -> URL {
    directory.appendingPathComponent("log-\(generation).ndjson")
  }

  static func generations(in directory: URL) -> [Int] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name -> Int? in
      guard name.hasPrefix("log-"), name.hasSuffix(".ndjson") else { return nil }
      return Int(name.dropFirst(4).dropLast(7))
    }.sorted()
  }

  func append(_ stored: [FeedbackLogBuffer.Stored]) {
    guard !stored.isEmpty else { return }
    let encoder = JSONEncoder()
    var chunk = Data()
    for s in stored {
      guard let line = try? encoder.encode(Line(s: s.seq, e: s.entry)) else { continue }
      chunk.append(line)
      chunk.append(0x0A)
    }
    if currentSize + chunk.count > maxBytes / 2, currentSize > 0 {
      try? FileManager.default.removeItem(at: LogDisk.url(directory, generation - 1))
      generation += 1
      currentSize = 0
    }
    let url = LogDisk.url(directory, generation)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(chunk)
      try? handle.close()
    } else {
      try? chunk.write(to: url, options: [.atomic])
    }
    currentSize += chunk.count
  }

  /// Every entry on disk, oldest first, the last copy of each.
  static func read(_ directory: URL) -> [FeedbackLogEntry] {
    let decoder = JSONDecoder()
    var bySeq: [Int64: FeedbackLogEntry] = [:]
    for gen in generations(in: directory).suffix(2) {
      guard let data = try? Data(contentsOf: url(directory, gen)) else { continue }
      for line in data.split(separator: 0x0A) {
        if let l = try? decoder.decode(Line.self, from: Data(line)) { bySeq[l.s] = l.e }
      }
    }
    return bySeq.keys.sorted().compactMap { bySeq[$0] }
  }

  static func removeAll(_ directory: URL) {
    for gen in generations(in: directory) {
      try? FileManager.default.removeItem(at: url(directory, gen))
    }
  }
}

/// The files: `session.json` (this session's marker), the rotating log files, `exception.json`,
/// `metrickit.json`, and `previous.json` (the unclosed session before this one, kept until the person
/// has answered the offer). In Application Support, excluded from backups.
public final class SessionStore: @unchecked Sendable {
  // @unchecked: every file read and write is under `lock`; `current` and `disk` only under it.
  public let directory: URL
  private let lock = NSLock()
  private var current: SessionMarker?
  private var disk: LogDisk?
  private let logBytes: Int

  public init(directory: URL, logBytes: Int = 4_000_000) {
    self.directory = directory
    self.logBytes = logBytes
  }

  /// `Application Support/OverblastFeedback/<bundle id>/session`: this app's alone, even in an
  /// unsandboxed Mac app, where a folder shared with other apps made one app take another's unclosed
  /// session for its own crash (`FeedbackStorage`).
  public static func defaultDirectory() -> URL {
    FeedbackStorage.directory("session")
  }

  private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

  // MARK: Lifecycle

  /// At launch: the last session, when it never closed, becomes `previous.json` (with its logs and
  /// its exception), and a new session opens with an empty log. Returns the unclosed previous
  /// session, or the one from an earlier launch still waiting for an answer.
  @discardableResult
  public func begin(now: Date = Date()) -> PreviousSession? {
    lock.lock()
    defer { lock.unlock() }
    ensureDirectory()
    var previous: PreviousSession? = read(PreviousSession.self, "previous.json")
    if let marker = read(SessionMarker.self, "session.json"), marker.isOpen {
      let logs = LogDisk.read(directory)
      let exception = read(ExceptionRecord.self, "exception.json")
      previous = PreviousSession(marker: marker, logs: logs, exception: exception)
      write(previous, "previous.json")
    }
    LogDisk.removeAll(directory)
    remove("exception.json")
    disk = LogDisk(directory: directory, maxBytes: logBytes)
    let marker = SessionMarker(startedAt: now)
    current = marker
    write(marker, "session.json")
    return previous
  }

  /// The app went to the background or is terminating cleanly.
  public func close(now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    guard var marker = current else { return }
    marker.lastSeenAt = now
    marker.closedAt = now
    current = marker
    write(marker, "session.json")
  }

  /// The app came back to the foreground: the same session, open again.
  public func reopen(now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    guard var marker = current, !marker.isOpen else { return }
    marker.closedAt = nil
    marker.lastSeenAt = now
    current = marker
    write(marker, "session.json")
  }

  public var currentSession: SessionMarker? {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  // MARK: Writes during the session

  /// Appends log entries to the disk copy and moves the marker's `lastSeenAt`.
  public func appendLogs(_ stored: [FeedbackLogBuffer.Stored], now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    guard let disk else { return }
    disk.append(stored)
    if var marker = current, marker.isOpen {
      marker.lastSeenAt = now
      current = marker
      write(marker, "session.json")
    }
  }

  /// This session's log as it is on disk.
  public func savedLogs() -> [FeedbackLogEntry] {
    lock.lock()
    defer { lock.unlock() }
    return LogDisk.read(directory)
  }

  /// Written by the uncaught-exception handler, synchronously, on the way down.
  public func recordException(name: String, reason: String?, stack: String?, now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    guard let marker = current else { return }
    write(ExceptionRecord(sessionId: marker.id, at: now, name: name, reason: reason, stack: stack), "exception.json")
  }

  /// MetricKit's newest crash. It arrives at a later launch than the crash it describes.
  public func recordMetricCrash(_ record: MetricCrashRecord) {
    lock.lock()
    defer { lock.unlock() }
    if let existing = read(MetricCrashRecord.self, "metrickit.json"), existing.end > record.end { return }
    write(record, "metrickit.json")
  }

  // MARK: The previous session

  public var previous: PreviousSession? {
    lock.lock()
    defer { lock.unlock() }
    return read(PreviousSession.self, "previous.json")
  }

  /// The `crash` for a report about the previous session, decided now, so a MetricKit diagnostic that
  /// arrived while the person was typing is included.
  public func crashForPrevious() -> FeedbackCrash? {
    lock.lock()
    defer { lock.unlock() }
    guard let previous = read(PreviousSession.self, "previous.json") else { return nil }
    return CrashDecision.crash(for: previous, metric: read(MetricCrashRecord.self, "metrickit.json"))
  }

  /// The person answered the offer (sent a report, or said not now): it is not made again.
  public func forgetPrevious() {
    lock.lock()
    defer { lock.unlock() }
    remove("previous.json")
    remove("metrickit.json")
  }

  // MARK: Files

  private func ensureDirectory() {
    guard !FileManager.default.fileExists(atPath: directory.path) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var dir = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
  }

  private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let data = try? Data(contentsOf: url(name)) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private func write<T: Encodable>(_ value: T?, _ name: String) {
    guard let value else { return }
    ensureDirectory()
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url(name), options: [.atomic])
  }

  private func remove(_ name: String) {
    try? FileManager.default.removeItem(at: url(name))
  }
}

/// Keeps the log buffer on disk as the app runs: at most every five seconds, and at once on an error,
/// so the lines just before a crash survive it. Writes happen on a utility queue of their own.
final class SessionRecorder: @unchecked Sendable {
  // @unchecked: `scheduled` is only touched under `lock`; the store and the buffer are thread-safe.
  let store: SessionStore
  let debounce: TimeInterval
  private let buffer: FeedbackLogBuffer
  private let queue = DispatchQueue(label: "network.deployd.overblast-feedback.session", qos: .utility)
  private let lock = NSLock()
  private var scheduled = false

  init(store: SessionStore, buffer: FeedbackLogBuffer, debounce: TimeInterval = 5) {
    self.store = store
    self.buffer = buffer
    self.debounce = debounce
  }

  /// A line was logged.
  func noteLog(_ level: FeedbackLogLevel) {
    if level == .error {
      queue.async { [self] in flushNow() }
      return
    }
    lock.lock()
    let start = !scheduled
    scheduled = true
    lock.unlock()
    if start {
      queue.asyncAfter(deadline: .now() + debounce) { [self] in flushNow() }
    }
  }

  /// Writes what is new now, on the calling thread (the exception handler, going to the background).
  func flushNow() {
    lock.lock()
    scheduled = false
    lock.unlock()
    store.appendLogs(buffer.takeUnsaved())
  }
}

/// The uncaught-exception handler: it writes the exception and the log buffer synchronously, then
/// calls whichever handler was installed before it (a crash reporter's, the app's own), so nobody
/// else's crash reporting is lost. No signal handlers: what a signal leaves behind is MetricKit's.
enum ExceptionHandler {
  nonisolated(unsafe) static var previous: (@convention(c) (NSException) -> Void)?
  nonisolated(unsafe) static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    previous = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      ExceptionHandler.record(exception)
      ExceptionHandler.previous?(exception)
    }
  }

  static func record(_ exception: NSException) {
    guard let recorder = Engine.shared.session else { return }
    let stack = exception.callStackSymbols.joined(separator: "\n")
    recorder.store.recordException(
      name: exception.name.rawValue,
      reason: exception.reason,
      stack: FeedbackText.truncate(Redactor.redact(stack), FeedbackLimits.crashStack)
    )
    recorder.flushNow()
  }
}

/// MetricKit's call-stack tree, turned into a few readable lines. Its JSON is
/// `{ "callStacks": [ { "threadAttributed": true, "callStackRootFrames": [ frame ] } ] }`, where a
/// frame is `{ binaryName, binaryUUID, address, offsetIntoBinaryTextSegment, subFrames: [frame] }`
/// and the first sub-frame is the caller. Foundation only, so it is tested on a fixture.
public enum MetricKitSummary {
  /// The crashed thread's frames, innermost first, one per line: `0 MyApp 0x1027c4a10 + 18960`. Nil
  /// when the JSON has no frames.
  public static func stack(fromCallStackTree json: Data, maxFrames: Int = 40) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty
    else { return nil }
    let thread = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
    guard var frame = (thread["callStackRootFrames"] as? [[String: Any]])?.first else { return nil }
    var lines: [String] = []
    while lines.count < maxFrames {
      let name = frame["binaryName"] as? String ?? "???"
      var line = "\(lines.count) \(name)"
      if let address = (frame["address"] as? NSNumber)?.uint64Value { line += " 0x" + String(address, radix: 16) }
      if let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value { line += " + \(offset)" }
      lines.append(line)
      guard let next = (frame["subFrames"] as? [[String: Any]])?.first else { break }
      frame = next
    }
    return lines.joined(separator: "\n")
  }

  /// One sentence from what the diagnostic says: `EXC_BAD_ACCESS (SIGSEGV): Namespace SIGNAL, Code 11`,
  /// or, for an Objective-C exception MetricKit caught, its name and reason.
  public static func message(exceptionType: Int?, signal: Int?, terminationReason: String?, exceptionName: String? = nil, exceptionReason: String? = nil) -> String {
    if let exceptionName, !exceptionName.isEmpty {
      return [exceptionName, exceptionReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    }
    var head = exceptionType.map(machExceptionName) ?? "Crash"
    if let signal { head += " (\(signalName(signal)))" }
    if let reason = terminationReason, !reason.isEmpty { return "\(head): \(reason)" }
    return head
  }

  static func machExceptionName(_ type: Int) -> String {
    switch type {
    case 1: return "EXC_BAD_ACCESS"
    case 2: return "EXC_BAD_INSTRUCTION"
    case 3: return "EXC_ARITHMETIC"
    case 4: return "EXC_EMULATION"
    case 5: return "EXC_SOFTWARE"
    case 6: return "EXC_BREAKPOINT"
    case 10: return "EXC_CRASH"
    case 11: return "EXC_RESOURCE"
    case 12: return "EXC_GUARD"
    default: return "Exception \(type)"
    }
  }

  static func signalName(_ signal: Int) -> String {
    switch signal {
    case 4: return "SIGILL"
    case 5: return "SIGTRAP"
    case 6: return "SIGABRT"
    case 8: return "SIGFPE"
    case 9: return "SIGKILL"
    case 10: return "SIGBUS"
    case 11: return "SIGSEGV"
    case 13: return "SIGPIPE"
    default: return "signal \(signal)"
    }
  }
}
