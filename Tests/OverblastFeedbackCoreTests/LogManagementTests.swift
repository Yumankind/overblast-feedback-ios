import XCTest
@testable import OverblastFeedbackCore

/// Contract §3.5, rule by rule: repeats, the per-second cap, redaction of kept lines only, the byte
/// and line budgets with priority eviction, the excerpt, and the gzip NDJSON file.
final class LogManagementTests: XCTestCase {
  private func line(_ t: Int64, _ level: FeedbackLogLevel = .info, _ msg: String = "hello", src: String? = "app") -> FeedbackLogEntry {
    FeedbackLogEntry(t: t, level: level, msg: msg, src: src)
  }

  // MARK: Repeats

  func testIdenticalLinesCollapseWithACountAndTheLastTime() throws {
    let buffer = FeedbackLogBuffer()
    for i in 0..<37 { buffer.append(line(1_000 + Int64(i) * 10, .warn, "retrying")) }
    buffer.append(line(2_000, .warn, "retrying", src: "other"))   // another source is another line
    buffer.append(line(2_010, .error, "retrying"))                // another level too
    let lines = buffer.snapshot()
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines[0].repeatCount, 37)
    XCTAssertEqual(lines[0].last, 1_360)
    XCTAssertEqual(lines[0].t, 1_000)
    XCTAssertNil(lines[1].repeatCount)
    // On the wire: `repeat` and `last`.
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: FeedbackPayload.encoder().encode(lines[0])) as? [String: Any])
    XCTAssertEqual(json["repeat"] as? Int, 37)
    XCTAssertEqual(json["last"] as? Int, 1_360)
    XCTAssertNil(json["repeatCount"])
  }

  func testRepeatsDoNotSpendTheIntakeAllowance() {
    let buffer = FeedbackLogBuffer()
    for i in 0..<500 { buffer.append(line(5_000 + Int64(i), .info, "tick")) }
    XCTAssertEqual(buffer.count, 1)
    XCTAssertEqual(buffer.snapshot().first?.repeatCount, 500)
  }

  // MARK: Intake

  func testFiftyALineASecondThenADroppedMarker() {
    let buffer = FeedbackLogBuffer()
    // 1,250 different lines spread over the second starting at 10 s, and two more seconds of storm.
    for i in 0..<1_250 { buffer.append(line(10_000 + Int64(i % 1000), .debug, "line \(i)")) }
    for i in 0..<100 { buffer.append(line(11_000 + Int64(i), .debug, "more \(i)")) }
    for i in 0..<100 { buffer.append(line(12_500 + Int64(i), .debug, "even more \(i)")) }
    // A quiet line in a later second is let in, and the gap is marked before it.
    buffer.append(line(20_000, .info, "calm again"))
    let lines = buffer.snapshot()
    let kept = lines.filter { $0.src == "app" }
    XCTAssertEqual(kept.count, 50 + 50 + 50 + 1)
    let markers = lines.filter { $0.src == FeedbackLogBuffer.source }
    XCTAssertFalse(markers.isEmpty)
    XCTAssertTrue(markers.allSatisfy { $0.level == .warn && $0.msg.hasSuffix("(too fast)") })
    XCTAssertEqual(markers.first?.msg, "1,200 lines dropped in 1 s (too fast)")
    XCTAssertEqual(lines.last?.msg, "calm again")
    XCTAssertEqual(lines[lines.count - 2].src, FeedbackLogBuffer.source)
  }

  func testWarningsAndErrorsHaveTheirOwnTwoHundred() {
    let buffer = FeedbackLogBuffer()
    for i in 0..<300 { buffer.append(line(30_000 + Int64(i), .error, "e\(i)")) }
    for i in 0..<300 { buffer.append(line(30_400 + Int64(i % 500), .debug, "d\(i)")) }
    let lines = buffer.snapshot()
    XCTAssertEqual(lines.filter { $0.level == .error }.count, 200)
    XCTAssertEqual(lines.filter { $0.level == .debug }.count, 50)
    // A pending gap is shown at the end of a snapshot even before the next line is let in.
    XCTAssertEqual(lines.last?.src, FeedbackLogBuffer.source)
    // The 100 errors over the cap are marked when the next line is let in; the 250 debug lines
    // after the cap are the pending marker at the end.
    XCTAssertTrue(lines.contains { $0.msg == "100 lines dropped in 1 s (too fast)" })
    XCTAssertEqual(lines.last?.msg, "250 lines dropped in 1 s (too fast)")
  }

  func testOnlyKeptLinesAreRedacted() {
    let buffer = FeedbackLogBuffer(limits: .init(perSecond: 1))
    XCTAssertTrue(buffer.append(line(1_000, .info, "token=abc123secret")))
    XCTAssertFalse(buffer.append(line(1_001, .info, "password=hunter2")))
    let lines = buffer.snapshot()
    XCTAssertEqual(lines[0].msg, "token=[redacted]")
    XCTAssertFalse(lines.contains { $0.msg.contains("hunter2") })
  }

  // MARK: Budgets

  func testTheLineBudgetEvictsDebugAndInfoBeforeWarningsAndErrors() {
    let buffer = FeedbackLogBuffer(limits: .init(maxLines: 10, perSecond: 10_000, urgentPerSecond: 10_000))
    buffer.append(line(1, .error, "old error"))
    buffer.append(line(2, .warn, "old warning"))
    for i in 0..<20 { buffer.append(line(10 + Int64(i), .debug, "debug \(i)")) }
    let lines = buffer.snapshot()
    XCTAssertEqual(lines.count, 10)
    XCTAssertEqual(lines.first?.msg, "old error")
    XCTAssertEqual(lines[1].msg, "old warning")
    XCTAssertEqual(lines.last?.msg, "debug 19")
    // With only warnings and errors left to evict, the oldest of those goes.
    for i in 0..<20 { buffer.append(line(100 + Int64(i), .error, "new error \(i)")) }
    XCTAssertFalse(buffer.snapshot().contains { $0.msg == "old error" })
  }

  func testTheByteBudget() {
    let buffer = FeedbackLogBuffer(limits: .init(maxBytes: 10_000, perSecond: 10_000))
    let text = String(repeating: "x", count: 952)       // 1,000 counted bytes with the allowance
    for i in 0..<30 { buffer.append(line(Int64(i), .info, text + "\(i)")) }
    XCTAssertLessThanOrEqual(buffer.byteCount, 10_000)
    XCTAssertEqual(buffer.count, 9)
    XCTAssertEqual(buffer.snapshot().last?.msg, text + "29")
  }

  func testTheDefaultBudgetsAreTheContracts() {
    let limits = FeedbackLogBuffer.Limits()
    XCTAssertEqual(limits.maxLines, 20_000)
    XCTAssertEqual(limits.maxBytes, 2_000_000)
    XCTAssertEqual(limits.perSecond, 50)
    XCTAssertEqual(limits.urgentPerSecond, 200)
  }

  func testSnapshotStopsAtTheMomentTheReportOpened() {
    let buffer = FeedbackLogBuffer()
    buffer.append(line(1_000, .info, "before"))
    buffer.append(line(2_000, .info, "after"))
    XCTAssertEqual(buffer.snapshot(until: 2_000).map(\.msg), ["before"])
  }

  // MARK: The excerpt

  func testTheExcerptTakesRecentWarningsAndErrorsFirstThenTheNewest() {
    let opened: Int64 = 1_000_000
    var entries: [FeedbackLogEntry] = []
    entries.append(line(opened - 110_000, .error, "error 110 s before"))
    entries.append(line(opened - 300_000, .error, "error five minutes before"))
    for i in 0..<1_000 { entries.append(line(opened - 100_000 + Int64(i) * 10, .debug, "debug \(i)")) }
    entries.append(line(opened + 5, .error, "after the report opened"))
    let excerpt = LogSelection.excerpt(entries.sorted { $0.t < $1.t }, openedAt: opened, limit: 10)
    XCTAssertEqual(excerpt.count, 10)
    XCTAssertTrue(excerpt.contains { $0.msg == "error 110 s before" })
    XCTAssertFalse(excerpt.contains { $0.msg == "error five minutes before" })
    XCTAssertFalse(excerpt.contains { $0.msg == "after the report opened" })
    XCTAssertEqual(excerpt.last?.msg, "debug 999")
    XCTAssertEqual(excerpt, excerpt.sorted { $0.t < $1.t })
  }

  func testTheExcerptKeepsToTheByteCap() throws {
    let big = String(repeating: "y", count: 3_000)
    let entries = (0..<200).map { line(Int64($0), .info, big + "\($0)") }
    let excerpt = LogSelection.excerpt(entries, openedAt: 10_000)
    let size = try FeedbackPayload.encoder().encode(excerpt).count
    XCTAssertLessThanOrEqual(size, FeedbackLimits.logBytes)
    XCTAssertGreaterThan(excerpt.count, 70)
  }

  // MARK: The file

  func testGzipRoundTripsThroughGunzip() throws {
    let text = Data((0..<2_000).map { "{\"t\":\($0),\"level\":\"info\",\"msg\":\"line \($0)\"}\n" }.joined().utf8)
    let gz = try XCTUnwrap(Gzip.compress(text))
    XCTAssertEqual(Array(gz.prefix(3)), [0x1F, 0x8B, 0x08])
    XCTAssertLessThan(gz.count, text.count / 3)
    XCTAssertEqual(Gzip.decompress(gz), text)
    XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    #if os(macOS)
    // And the system's own gunzip agrees, which is what the worker's DecompressionStream does too.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("obf-\(UUID().uuidString).gz")
    try gz.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(out, text)
    #endif
    XCTAssertEqual(Gzip.decompress(try XCTUnwrap(Gzip.compress(Data()))), Data())
  }

  func testTheFileIsNDJSONOldestFirst() throws {
    let entries = [line(3, .info, "c"), line(1, .warn, "a", src: "oslog"), line(2, .error, "b")]
    let file = try XCTUnwrap(LogFileBuilder.build(entries))
    XCTAssertEqual(file.contentType, "application/x-ndjson")
    XCTAssertEqual(file.encoding, "gzip")
    XCTAssertEqual(file.lines, 3)
    XCTAssertEqual(file.from, 1)
    XCTAssertEqual(file.to, 3)
    let text = String(decoding: try XCTUnwrap(Gzip.decompress(try XCTUnwrap(Data(base64Encoded: file.base64)))), as: UTF8.self)
    let lines = text.split(separator: "\n").map { try! JSONDecoder().decode(FeedbackLogEntry.self, from: Data($0.utf8)) }
    XCTAssertEqual(lines.map(\.msg), ["a", "b", "c"])
  }

  func testAFileOverTheBudgetLosesItsOldestLinesAndSaysSo() throws {
    // Lines that do not compress: random text.
    var rng = SystemRandomNumberGenerator()
    let entries = (0..<4_000).map { i -> FeedbackLogEntry in
      let noise = (0..<120).map { _ in String(UnicodeScalar(UInt8(33 + Int(rng.next() % 90)))) }.joined()
      return line(1_760_440_000_000 + Int64(i) * 1_000, .info, noise)
    }
    let budget = 100_000
    let file = try XCTUnwrap(LogFileBuilder.build(entries, budget: budget, timeZone: TimeZone(identifier: "UTC")!))
    XCTAssertLessThanOrEqual(file.decodedByteCount, budget)
    let text = String(decoding: try XCTUnwrap(Gzip.decompress(try XCTUnwrap(Data(base64Encoded: file.base64)))), as: UTF8.self)
    let lines = text.split(separator: "\n").map { try! JSONDecoder().decode(FeedbackLogEntry.self, from: Data($0.utf8)) }
    let first = try XCTUnwrap(lines.first)
    XCTAssertEqual(first.src, FeedbackLogBuffer.source)
    XCTAssertEqual(first.level, .warn)
    XCTAssertTrue(first.msg.hasPrefix("older lines cut to fit: "), first.msg)
    XCTAssertTrue(first.msg.contains(" from 11:06 to "), first.msg)
    XCTAssertEqual(lines.count, file.lines)
    XCTAssertEqual(lines.last?.t, entries.last?.t)
    XCTAssertLessThan(lines.count, entries.count)
    // Not cut to nothing: most of the budget is used.
    XCTAssertGreaterThan(file.decodedByteCount, budget / 2)
  }

  func testTheLogFileShrinksToFitTheBodyBeforeTheScreenshot() {
    let screenshot = FeedbackScreenshot(jpeg: Data(repeating: 0xAB, count: FeedbackLimits.screenshotBytes - 10), highlighted: false)
    let payload = FeedbackPayload(message: "m", context: FeedbackContext(), screenshot: screenshot)
    let budget = OverblastFeedback.logFileBudget(for: payload)
    XCTAssertLessThan(budget, LogFileBuilder.maxBytes)
    XCTAssertGreaterThan(budget, 0)
    // Base64 of the budget plus the rest fits the 8 MB body.
    XCTAssertLessThanOrEqual(payload.encodedSize() + budget / 3 * 4 + 200, FeedbackLimits.bodyBytes)
    XCTAssertEqual(OverblastFeedback.logFileBudget(for: FeedbackPayload(message: "m", context: FeedbackContext())), LogFileBuilder.maxBytes)
  }

  // MARK: The unified log's filter

  func testOnlyTheAppsOwnUnifiedLogLinesAreKept() {
    let t0 = Date(timeIntervalSince1970: 1_760_440_000)
    let lines: [OSLogCollector.Line] = [
      .init(date: t0, level: .notice, subsystem: "", message: "NSLog from the app"),
      .init(date: t0.addingTimeInterval(1), level: .debug, subsystem: "", message: "app debug"),
      .init(date: t0.addingTimeInterval(2), level: .info, subsystem: "com.apple.UIKit", message: "Sending UIEvent type: 0"),
      .init(date: t0.addingTimeInterval(3), level: .error, subsystem: "com.apple.runningboard", message: "assertion"),
      .init(date: t0.addingTimeInterval(4), level: .error, subsystem: "com.example.cart", message: "checkout failed"),
      .init(date: t0.addingTimeInterval(5), level: .fault, subsystem: "com.applesauce.app", message: "not Apple's"),
      .init(date: t0.addingTimeInterval(6), level: .undefined, subsystem: "", message: "undefined level"),
      .init(date: t0.addingTimeInterval(20), level: .error, subsystem: "", message: "after the sheet opened"),
    ]
    let kept = OSLogCollector.select(lines, until: t0.addingTimeInterval(10))
    XCTAssertEqual(kept.map(\.msg), ["NSLog from the app", "checkout failed", "not Apple's"])
    XCTAssertEqual(kept.map(\.level), [.info, .error, .error])
    XCTAssertTrue(kept.allSatisfy { $0.src == "oslog" })
    // The newest 500 are taken after the filter: noise cannot push the app's lines out.
    let noisy = (0..<2_000).map { OSLogCollector.Line(date: t0.addingTimeInterval(Double($0) / 100), level: .info, subsystem: "com.apple.UIKit", message: "noise") }
    let mixed = [OSLogCollector.Line(date: t0, level: .notice, subsystem: "", message: "mine")] + noisy
    XCTAssertEqual(OSLogCollector.select(mixed, limit: 500).map(\.msg), ["mine"])
  }
}
