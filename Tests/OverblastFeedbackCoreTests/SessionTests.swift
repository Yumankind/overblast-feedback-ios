import XCTest
@testable import OverblastFeedbackCore

/// Contract §3.4: the session marker, the log kept on disk, the exception and MetricKit records, the
/// decision of what `crash` a report about the previous session carries, and the new body fields.
final class SessionTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("obf-session-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func stored(_ seq: Int64, _ msg: String, level: FeedbackLogLevel = .info, t: Int64 = 1_000) -> FeedbackLogBuffer.Stored {
    FeedbackLogBuffer.Stored(seq: seq, entry: FeedbackLogEntry(t: t, level: level, msg: msg, src: "app"))
  }

  // MARK: The marker

  func testACleanlyClosedSessionIsNotAPreviousSession() {
    let first = SessionStore(directory: directory)
    XCTAssertNil(first.begin(now: Date(timeIntervalSince1970: 100)))
    first.appendLogs([stored(1, "hello")])
    first.close(now: Date(timeIntervalSince1970: 200))
    let second = SessionStore(directory: directory)
    XCTAssertNil(second.begin(now: Date(timeIntervalSince1970: 300)))
    XCTAssertNil(second.previous)
    XCTAssertEqual(second.savedLogs(), [], "a new session starts with an empty log")
  }

  func testGoingToTheBackgroundAndBackIsTheSameSessionOpenAgain() {
    let store = SessionStore(directory: directory)
    store.begin(now: Date(timeIntervalSince1970: 100))
    store.close(now: Date(timeIntervalSince1970: 150))
    XCTAssertFalse(store.currentSession!.isOpen)
    store.reopen(now: Date(timeIntervalSince1970: 160))
    XCTAssertTrue(store.currentSession!.isOpen)
    // Killed while open: the next launch sees it.
    let next = SessionStore(directory: directory)
    let previous = next.begin(now: Date(timeIntervalSince1970: 400))
    XCTAssertEqual(previous?.marker.startedAt, Date(timeIntervalSince1970: 100))
  }

  func testAnUnclosedSessionComesBackWithItsLogsAndIsOfferedUntilAnswered() throws {
    let first = SessionStore(directory: directory)
    first.begin(now: Date(timeIntervalSince1970: 100))
    first.appendLogs([stored(1, "loading cart"), stored(2, "tapped checkout", level: .warn)], now: Date(timeIntervalSince1970: 130))
    first.appendLogs([stored(2, "tapped checkout", level: .warn)].map { var s = $0; s.entry.repeatCount = 3; return s }, now: Date(timeIntervalSince1970: 140))
    // ...and the app dies here, without close().

    let second = SessionStore(directory: directory)
    let previous = try XCTUnwrap(second.begin(now: Date(timeIntervalSince1970: 500)))
    XCTAssertEqual(previous.logs.map(\.msg), ["loading cart", "tapped checkout"])
    XCTAssertEqual(previous.logs.last?.repeatCount, 3, "the last copy of a line wins")
    XCTAssertEqual(previous.marker.lastSeenAt, Date(timeIntervalSince1970: 140))
    XCTAssertEqual(second.crashForPrevious(), FeedbackCrash(kind: .unknown, at: 140_000, source: .marker))

    // Not answered, and the app closes cleanly: still offered at the next launch.
    second.close()
    let third = SessionStore(directory: directory)
    XCTAssertEqual(third.begin()?.marker.id, previous.marker.id)
    third.forgetPrevious()
    XCTAssertNil(third.previous)
    XCTAssertNil(third.crashForPrevious())
  }

  func testTheExceptionOfThatSessionWins() throws {
    let first = SessionStore(directory: directory)
    first.begin(now: Date(timeIntervalSince1970: 100))
    first.recordException(name: "NSInvalidArgumentException", reason: "-[NSNull length]: unrecognized selector", stack: "0 CoreFoundation\n1 MyApp", now: Date(timeIntervalSince1970: 120))
    let second = SessionStore(directory: directory)
    let previous = try XCTUnwrap(second.begin())
    XCTAssertEqual(previous.exception?.name, "NSInvalidArgumentException")
    second.recordMetricCrash(MetricCrashRecord(begin: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000), message: "EXC_CRASH (SIGABRT)", stack: nil))
    let crash = try XCTUnwrap(second.crashForPrevious())
    XCTAssertEqual(crash.kind, .exception)
    XCTAssertEqual(crash.source, .handler)
    XCTAssertEqual(crash.message, "NSInvalidArgumentException: -[NSNull length]: unrecognized selector")
    XCTAssertEqual(crash.stack, "0 CoreFoundation\n1 MyApp")
    XCTAssertEqual(crash.at, 120_000)
  }

  func testMetricKitIsMatchedToTheSessionByTime() {
    let marker = SessionMarker(startedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: Date(timeIntervalSince1970: 2_000))
    let previous = PreviousSession(marker: marker, logs: [], exception: nil)
    let covering = MetricCrashRecord(begin: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 90_000), message: "EXC_BAD_ACCESS (SIGSEGV)", stack: "0 MyApp 0x10")
    let earlier = MetricCrashRecord(begin: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 500), message: "old", stack: nil)
    XCTAssertTrue(CrashDecision.matches(covering, marker))
    XCTAssertFalse(CrashDecision.matches(earlier, marker))
    XCTAssertEqual(CrashDecision.crash(for: previous, metric: covering),
                   FeedbackCrash(kind: .crash, at: 2_000_000, message: "EXC_BAD_ACCESS (SIGSEGV)", stack: "0 MyApp 0x10", source: .metrickit))
    XCTAssertEqual(CrashDecision.crash(for: previous, metric: earlier).kind, .unknown)
    // An exception recorded by another session does not count.
    let stray = PreviousSession(marker: marker, logs: [], exception: ExceptionRecord(sessionId: "other", at: Date(), name: "X", reason: nil, stack: nil))
    XCTAssertEqual(CrashDecision.crash(for: stray, metric: nil).source, .marker)
  }

  func testTheNewestMetricKitCrashIsKept() throws {
    let store = SessionStore(directory: directory)
    store.begin()
    store.recordMetricCrash(MetricCrashRecord(begin: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200), message: "newer", stack: nil))
    store.recordMetricCrash(MetricCrashRecord(begin: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100), message: "older", stack: nil))
    let data = try Data(contentsOf: directory.appendingPathComponent("metrickit.json"))
    XCTAssertEqual(try JSONDecoder().decode(MetricCrashRecord.self, from: data).message, "newer")
  }

  // MARK: The log on disk

  func testTheDiskCopyRotatesBetweenTwoFilesWithinItsBudget() throws {
    let store = SessionStore(directory: directory, logBytes: 20_000)
    store.begin()
    let text = String(repeating: "z", count: 400)
    for i in 0..<200 { store.appendLogs([stored(Int64(i), text + "\(i)", t: Int64(i))]) }
    let files = LogDisk.generations(in: directory)
    XCTAssertEqual(files.count, 2, "\(files)")
    let total = try files.reduce(0) { $0 + (try Data(contentsOf: LogDisk.url(directory, $1)).count) }
    XCTAssertLessThanOrEqual(total, 20_000)
    let saved = store.savedLogs()
    XCTAssertEqual(saved.last?.msg, text + "199")
    XCTAssertLessThan(saved.count, 200, "the oldest file went")
    XCTAssertEqual(saved, saved.sorted { $0.t < $1.t })
  }

  func testTheRecorderWritesAtOnceOnAnErrorAndLaterOtherwise() throws {
    let store = SessionStore(directory: directory)
    store.begin()
    let buffer = FeedbackLogBuffer()
    let recorder = SessionRecorder(store: store, buffer: buffer, debounce: 30)
    buffer.append(FeedbackLogEntry(t: 1, level: .info, msg: "quiet", src: "app"))
    recorder.noteLog(.info)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(store.savedLogs(), [], "debounced")
    buffer.append(FeedbackLogEntry(t: 2, level: .error, msg: "boom", src: "app"))
    recorder.noteLog(.error)
    let deadline = Date().addingTimeInterval(3)
    while store.savedLogs().count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    XCTAssertEqual(store.savedLogs().map(\.msg), ["quiet", "boom"])
  }

  // MARK: MetricKit's JSON

  func testTheCallStackTreeIsSummarisedFromTheCrashedThread() throws {
    let fixture = """
    {
      "callStackPerThread": true,
      "callStacks": [
        { "threadAttributed": false, "callStackRootFrames": [ { "binaryName": "libsystem_kernel.dylib", "address": 7000, "offsetIntoBinaryTextSegment": 1, "sampleCount": 1 } ] },
        { "threadAttributed": true, "callStackRootFrames": [
          { "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment": 123, "sampleCount": 1,
            "binaryName": "MyApp", "address": 4338371088,
            "subFrames": [ { "binaryName": "UIKitCore", "address": 7451215360, "offsetIntoBinaryTextSegment": 456, "sampleCount": 1,
              "subFrames": [ { "binaryName": "libdyld.dylib", "address": 6865000000, "sampleCount": 1 } ] } ] } ] }
      ]
    }
    """
    let stack = try XCTUnwrap(MetricKitSummary.stack(fromCallStackTree: Data(fixture.utf8)))
    XCTAssertEqual(stack, """
    0 MyApp 0x102964a10 + 123
    1 UIKitCore 0x1bc208600 + 456
    2 libdyld.dylib 0x1992f9640
    """)
    XCTAssertEqual(MetricKitSummary.stack(fromCallStackTree: Data(fixture.utf8), maxFrames: 1), "0 MyApp 0x102964a10 + 123")
    XCTAssertNil(MetricKitSummary.stack(fromCallStackTree: Data("{}".utf8)))
    XCTAssertNil(MetricKitSummary.stack(fromCallStackTree: Data("not json".utf8)))
  }

  func testTheCrashMessage() {
    XCTAssertEqual(MetricKitSummary.message(exceptionType: 1, signal: 11, terminationReason: "Namespace SIGNAL, Code 11"), "EXC_BAD_ACCESS (SIGSEGV): Namespace SIGNAL, Code 11")
    XCTAssertEqual(MetricKitSummary.message(exceptionType: 10, signal: 6, terminationReason: nil), "EXC_CRASH (SIGABRT)")
    XCTAssertEqual(MetricKitSummary.message(exceptionType: nil, signal: nil, terminationReason: nil), "Crash")
    XCTAssertEqual(MetricKitSummary.message(exceptionType: 10, signal: 6, terminationReason: nil, exceptionName: "NSRangeException", exceptionReason: "index 3 beyond bounds"), "NSRangeException: index 3 beyond bounds")
  }

  // MARK: The body

  func testCrashOpenedAtAndTriggerOnTheWire() throws {
    let crash = FeedbackCrash(kind: .exception, at: 5, message: "Boom with token=abc123", stack: String(repeating: "s", count: 20_000), source: .handler)
    let payload = FeedbackPayload(message: "m", context: FeedbackContext(openedAt: 1_760_440_000_000, trigger: .relaunch), crash: crash)
    let clean = try payload.sanitized()
    XCTAssertEqual(clean.crash?.message, "Boom with token=[redacted]")
    XCTAssertLessThanOrEqual(clean.crash?.stack?.utf16.count ?? 0, FeedbackLimits.crashStack)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: FeedbackPayload.encoder().encode(clean)) as? [String: Any])
    let c = try XCTUnwrap(json["crash"] as? [String: Any])
    XCTAssertEqual(Set(c.keys), ["kind", "at", "message", "stack", "source"])
    XCTAssertEqual(c["kind"] as? String, "exception")
    XCTAssertEqual(c["source"] as? String, "handler")
    let context = try XCTUnwrap(json["context"] as? [String: Any])
    XCTAssertEqual(context["openedAt"] as? Int64, 1_760_440_000_000)
    XCTAssertEqual(context["trigger"] as? String, "relaunch")
    XCTAssertEqual(FeedbackCrash.Source.exitInfo.rawValue, "exit_info")
    XCTAssertEqual(Set(FeedbackTrigger.allCases.map(\.rawValue)), ["shake", "button", "shortcut", "agent", "api", "relaunch", "error_prompt"])
  }

  func testBuildPayloadStampsTheReportAndCarriesBothLogParts() async throws {
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000",
      endpoint: URL(string: "https://feedback.test/v1/feedback")!,
      reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: nil, store: PendingStore(directory: directory.appendingPathComponent("pending")),
      defaults: scratchDefaults("obf-tests")
    )
    OverblastFeedback.logBuffer.removeAll()
    OverblastFeedback.error("checkout failed: token=sk-abcdefghijklmnopqrstuvwx")
    OverblastFeedback.info("cart loaded")
    let opened = Date().addingTimeInterval(1)
    let payload = try await OverblastFeedback.buildPayload(message: "broken", trigger: .shake, openedAt: opened)
    XCTAssertEqual(payload.context.trigger, .shake)
    XCTAssertEqual(payload.context.openedAt, Int64((opened.timeIntervalSince1970 * 1000).rounded()))
    XCTAssertEqual(payload.logs?.map(\.msg), ["checkout failed: token=[redacted]", "cart loaded"])
    // The excerpt holds every line, so there is no file.
    XCTAssertNil(payload.logFile)

    // More than the excerpt can hold: the file carries everything.
    let many = (0..<800).map { FeedbackLogEntry(t: 1_000 + Int64($0), level: .info, msg: "line \($0) password=hunter2", src: "app") }
    let big = try await OverblastFeedback.buildPayload(message: "broken", logs: many, openedAt: opened)
    XCTAssertEqual(big.logs?.count, 500)
    let file = try XCTUnwrap(big.logFile)
    XCTAssertEqual(file.lines, 800)
    XCTAssertEqual(file.from, 1_000)
    XCTAssertEqual(big.context.trigger, .api)
    // A crash makes it a bug, whatever was chosen.
    let crashed = try await OverblastFeedback.buildPayload(message: "x", category: .idea, logs: [], trigger: .relaunch, crash: FeedbackCrash(kind: .unknown, source: .marker))
    XCTAssertEqual(crashed.category, .bug)
    XCTAssertNil(crashed.logs)
    XCTAssertNil(crashed.logFile)
  }
}
