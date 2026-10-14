import Foundation

/// A fixed-size ring of the most recent entries, safe to append to from any thread.
///
/// Appending is a lock, a copy and an index bump: nothing is redacted, formatted or allocated beyond
/// the entry itself, because `OverblastFeedback.log` may sit on a hot path in somebody's app.
/// Redaction happens once, when a report is built (`FeedbackPayload.sanitized()`).
public final class RingBuffer<Element: Sendable>: @unchecked Sendable {
  // @unchecked: every access to `storage`, `next` and `count` is under `lock`.
  private let lock = NSLock()
  private var storage: [Element?]
  private var next = 0
  private var filled = 0
  public let capacity: Int

  public init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.storage = Array(repeating: nil, count: capacity)
  }

  public func append(_ element: Element) {
    lock.lock()
    storage[next] = element
    next = (next + 1) % capacity
    filled = min(filled + 1, capacity)
    lock.unlock()
  }

  /// Oldest first.
  public func snapshot() -> [Element] {
    lock.lock()
    defer { lock.unlock() }
    var out: [Element] = []
    out.reserveCapacity(filled)
    let start = filled == capacity ? next : 0
    for i in 0..<filled {
      if let e = storage[(start + i) % capacity] { out.append(e) }
    }
    return out
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return filled
  }

  public func removeAll() {
    lock.lock()
    storage = Array(repeating: nil, count: capacity)
    next = 0
    filled = 0
    lock.unlock()
  }
}

extension FeedbackLogEntry {
  static func now(_ level: FeedbackLogLevel, _ msg: String, src: String?) -> FeedbackLogEntry {
    FeedbackLogEntry(t: Int64((Date().timeIntervalSince1970 * 1000).rounded()), level: level, msg: msg, src: src)
  }
}
