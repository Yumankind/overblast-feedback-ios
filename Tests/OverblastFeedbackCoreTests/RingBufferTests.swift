import XCTest
@testable import OverblastFeedbackCore

final class RingBufferTests: XCTestCase {
  func testKeepsTheNewestInOrder() {
    let ring = RingBuffer<Int>(capacity: 5)
    for i in 0..<12 { ring.append(i) }
    XCTAssertEqual(ring.snapshot(), [7, 8, 9, 10, 11])
    XCTAssertEqual(ring.count, 5)
  }

  func testBelowCapacity() {
    let ring = RingBuffer<Int>(capacity: 5)
    ring.append(1)
    ring.append(2)
    XCTAssertEqual(ring.snapshot(), [1, 2])
    ring.removeAll()
    XCTAssertEqual(ring.snapshot(), [])
  }

  func testConcurrentAppendsAndReads() {
    let ring = RingBuffer<FeedbackLogEntry>(capacity: FeedbackLimits.logEntries)
    DispatchQueue.concurrentPerform(iterations: 20_000) { i in
      ring.append(FeedbackLogEntry(t: Int64(i), level: .info, msg: "line \(i)"))
      if i % 100 == 0 { _ = ring.snapshot() }
    }
    let snapshot = ring.snapshot()
    XCTAssertEqual(snapshot.count, 500)
    XCTAssertEqual(Set(snapshot.map(\.t)).count, 500)
  }

  func testTheLogAPIWritesIntoTheSharedBuffer() {
    OverblastFeedback.logBuffer.removeAll()
    OverblastFeedback.log(.warn, "careful")
    OverblastFeedback.error("broke")
    let lines = OverblastFeedback.logBuffer.snapshot()
    XCTAssertEqual(lines.map(\.level), [.warn, .error])
    XCTAssertEqual(lines.map(\.msg), ["careful", "broke"])
    XCTAssertEqual(lines.first?.src, "app")
    XCTAssertGreaterThan(lines.first?.t ?? 0, 1_700_000_000_000)
  }

  func testMergeIsByTimeAndKeepsTheNewest() {
    let a = [FeedbackLogEntry(t: 1, level: .info, msg: "a1"), FeedbackLogEntry(t: 5, level: .info, msg: "a5")]
    let b = [FeedbackLogEntry(t: 3, level: .info, msg: "b3"), FeedbackLogEntry(t: 7, level: .info, msg: "b7")]
    XCTAssertEqual(OSLogCollector.merge(a, b).map(\.msg), ["a1", "b3", "a5", "b7"])
    XCTAssertEqual(OSLogCollector.merge(a, b, limit: 2).map(\.msg), ["a5", "b7"])
  }
}
