import Foundation

/// The log buffer every report's logs come from (contract §3.5), safe to append to from any thread.
///
/// Four rules keep it bounded however fast or long an app logs:
///
/// - **Repeats collapse.** A line identical to the one stored before it (same level, source and text)
///   is not stored again: that entry's `repeatCount` grows and `last` moves. The comparison is on the
///   raw text, before redaction, so a repeat costs one string comparison.
/// - **Intake is capped per second.** At most 50 lines a second enter (warnings and errors always do,
///   up to 200 a second); past that lines are counted and dropped, and one `warn` entry from
///   `overblast` ("1,204 lines dropped in 3 s (too fast)") marks the gap. Redaction runs only on the
///   lines that are kept, so a storm costs little.
/// - **A byte budget as well as a count:** 2 MB and 20,000 lines. When full, the oldest go first,
///   debug and info before warnings and errors, so an error from five minutes ago outlives a thousand
///   debug lines from the last second.
/// - **Time is the entry's own.** The per-second window is the entry's `t`, so the same rules can be
///   run over lines read back from the unified log after the fact.
public final class FeedbackLogBuffer: @unchecked Sendable {
  // @unchecked: every stored property below `lock` is only touched under it.
  public struct Limits: Sendable, Equatable {
    public var maxLines: Int
    public var maxBytes: Int
    public var perSecond: Int
    public var urgentPerSecond: Int

    public init(maxLines: Int = 20_000, maxBytes: Int = 2_000_000, perSecond: Int = 50, urgentPerSecond: Int = 200) {
      self.maxLines = maxLines
      self.maxBytes = maxBytes
      self.perSecond = perSecond
      self.urgentPerSecond = urgentPerSecond
    }
  }

  /// An entry with its place in the order of arrival, which is what the disk copy keys on.
  public struct Stored: Sendable, Equatable {
    public var seq: Int64
    public var entry: FeedbackLogEntry
  }

  public static let source = "overblast"

  public let limits: Limits
  private let lock = NSLock()
  private var low = Deque()
  private var high = Deque()
  private var bytes = 0
  private var seq: Int64 = 0
  /// The last stored line's identity (level, source, raw text), for collapsing repeats.
  private var lastKey: (level: FeedbackLogLevel, src: String?, raw: String)?
  private var lastSeq: Int64 = -1
  private var lastIsHigh = false
  private var windowSecond: Int64 = .min
  private var normalCount = 0
  private var urgentCount = 0
  private var dropped = 0
  private var dropFrom: Int64 = 0
  private var dropTo: Int64 = 0
  /// Stored and changed entries not yet written to disk, oldest first.
  private var unsaved: [Stored] = []

  public init(limits: Limits = Limits()) {
    self.limits = limits
  }

  // MARK: Intake

  /// Offers a line. Returns false when it was dropped by the per-second cap.
  @discardableResult
  public func append(_ entry: FeedbackLogEntry) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    if let key = lastKey, key.level == entry.level, key.src == entry.src, key.raw == entry.msg,
       bumpLast(at: entry.t) {
      return true
    }

    let second = entry.t >= 0 ? entry.t / 1000 : (entry.t - 999) / 1000
    if second != windowSecond {
      windowSecond = second
      normalCount = 0
      urgentCount = 0
    }
    let urgent = entry.level == .warn || entry.level == .error
    if urgent, urgentCount < limits.urgentPerSecond {
      urgentCount += 1
    } else if !urgent, normalCount < limits.perSecond {
      normalCount += 1
    } else {
      if dropped == 0 { dropFrom = entry.t }
      dropped += 1
      dropTo = entry.t
      lastKey = nil
      return false
    }

    emitDropMarker()
    var kept = entry
    kept.msg = FeedbackText.truncate(Redactor.redact(entry.msg), FeedbackLimits.logMessage)
    kept.src = FeedbackText.optional(entry.src, FeedbackLimits.logSource)
    store(kept)
    lastKey = (entry.level, entry.src, entry.msg)
    return true
  }

  /// Appends every line, in time order, through the same rules.
  public func append(contentsOf entries: [FeedbackLogEntry]) {
    for e in entries.sorted(by: { $0.t < $1.t }) { append(e) }
  }

  private func bumpLast(at t: Int64) -> Bool {
    let deque = lastIsHigh ? high : low
    guard var stored = deque.last, stored.seq == lastSeq else { return false }
    stored.entry.repeatCount = (stored.entry.repeatCount ?? 1) + 1
    stored.entry.last = max(t, stored.entry.last ?? stored.entry.t)
    if lastIsHigh { high.replaceLast(stored) } else { low.replaceLast(stored) }
    unsaved.append(Stored(seq: stored.seq, entry: stored.entry))
    return true
  }

  private func emitDropMarker() {
    guard dropped > 0 else { return }
    let marker = Self.dropMarker(count: dropped, from: dropFrom, to: dropTo)
    dropped = 0
    store(marker)
    lastKey = nil
  }

  /// `1,204 lines dropped in 3 s (too fast)`, at the time of the last dropped line.
  static func dropMarker(count: Int, from: Int64, to: Int64) -> FeedbackLogEntry {
    let seconds = max(1, Int((Double(max(0, to - from)) / 1000).rounded(.up)))
    let noun = count == 1 ? "line" : "lines"
    return FeedbackLogEntry(t: to, level: .warn, msg: "\(grouped(count)) \(noun) dropped in \(seconds) s (too fast)", src: source)
  }

  private func store(_ entry: FeedbackLogEntry) {
    seq += 1
    let stored = Stored(seq: seq, entry: entry)
    let urgent = entry.level == .warn || entry.level == .error
    if urgent { high.append(stored) } else { low.append(stored) }
    lastSeq = seq
    lastIsHigh = urgent
    bytes += Self.size(of: entry)
    unsaved.append(stored)
    if unsaved.count > limits.maxLines { unsaved.removeFirst(unsaved.count - limits.maxLines) }
    while (low.count + high.count > limits.maxLines || bytes > limits.maxBytes), low.count + high.count > 1 {
      let evicted = low.count > 0 ? low.popFirst() : high.popFirst()
      if let evicted { bytes -= Self.size(of: evicted.entry) }
    }
  }

  /// What an entry is counted as against the 2 MB: its text and a fixed allowance for the rest.
  static func size(of entry: FeedbackLogEntry) -> Int {
    entry.msg.utf8.count + (entry.src?.utf8.count ?? 0) + 48
  }

  // MARK: Reading

  /// Every entry, oldest first, with a pending "dropped" marker at the end; only those before
  /// `until` (unix ms) when given.
  public func snapshot(until: Int64? = nil) -> [FeedbackLogEntry] {
    storedSnapshot(until: until).map(\.entry)
  }

  public func storedSnapshot(until: Int64? = nil) -> [Stored] {
    lock.lock()
    defer { lock.unlock() }
    var out = Deque.merge(low, high)
    if dropped > 0 {
      out.append(Stored(seq: seq + 1, entry: Self.dropMarker(count: dropped, from: dropFrom, to: dropTo)))
    }
    if let until { out.removeAll { $0.entry.t >= until } }
    return out
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return low.count + high.count
  }

  public var byteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }

  public func removeAll() {
    lock.lock()
    low = Deque()
    high = Deque()
    bytes = 0
    lastKey = nil
    lastSeq = -1
    dropped = 0
    windowSecond = .min
    unsaved.removeAll()
    lock.unlock()
  }

  /// The entries stored or changed since the last call, for the disk copy. A changed entry (a repeat
  /// counted) comes again with the same `seq`; the reader keeps the last copy.
  func takeUnsaved() -> [Stored] {
    lock.lock()
    defer { lock.unlock() }
    let out = unsaved
    unsaved.removeAll(keepingCapacity: true)
    return out
  }

  static func grouped(_ n: Int) -> String {
    let digits = String(n)
    var out = ""
    for (i, ch) in digits.reversed().enumerated() {
      if i > 0, i % 3 == 0 { out.append(",") }
      out.append(ch)
    }
    return String(out.reversed())
  }
}

/// A first-in-first-out list with cheap removal at the front.
struct Deque {
  private var items: [FeedbackLogBuffer.Stored] = []
  private var head = 0

  var count: Int { items.count - head }
  var last: FeedbackLogBuffer.Stored? { count > 0 ? items[items.count - 1] : nil }

  mutating func append(_ item: FeedbackLogBuffer.Stored) { items.append(item) }

  mutating func replaceLast(_ item: FeedbackLogBuffer.Stored) {
    guard count > 0 else { return }
    items[items.count - 1] = item
  }

  mutating func popFirst() -> FeedbackLogBuffer.Stored? {
    guard count > 0 else { return nil }
    let item = items[head]
    head += 1
    if head > 1024, head * 2 > items.count {
      items.removeFirst(head)
      head = 0
    }
    return item
  }

  var elements: ArraySlice<FeedbackLogBuffer.Stored> { items[head...] }

  /// Both lists in order of arrival.
  static func merge(_ a: Deque, _ b: Deque) -> [FeedbackLogBuffer.Stored] {
    var out: [FeedbackLogBuffer.Stored] = []
    out.reserveCapacity(a.count + b.count)
    var i = a.elements.startIndex, j = b.elements.startIndex
    let ea = a.elements, eb = b.elements
    while i < ea.endIndex, j < eb.endIndex {
      if ea[i].seq < eb[j].seq { out.append(ea[i]); i += 1 } else { out.append(eb[j]); j += 1 }
    }
    out.append(contentsOf: ea[i...])
    out.append(contentsOf: eb[j...])
    return out
  }
}

/// The two parts of a report's logs (contract §3.5).
public enum LogSelection {
  /// The excerpt sent as `logs`: every warning and error in the two minutes before `openedAt`, then
  /// the newest other lines, at most `limit` entries and `bytes` encoded; oldest first.
  public static func excerpt(_ entries: [FeedbackLogEntry], openedAt: Int64, limit: Int = FeedbackLimits.logEntries, bytes: Int = FeedbackLimits.logBytes) -> [FeedbackLogEntry] {
    let before = entries.filter { $0.t < openedAt }
    let encoder = FeedbackPayload.encoder()
    var chosen = Set<Int>()
    var used = 2
    func take(_ index: Int) -> Bool {
      guard chosen.count < limit else { return false }
      let size = ((try? encoder.encode(before[index]).count) ?? 0) + 1
      guard used + size <= bytes else { return false }
      chosen.insert(index)
      used += size
      return true
    }
    let windowStart = openedAt - 120_000
    for index in before.indices.reversed() where before[index].t >= windowStart && (before[index].level == .warn || before[index].level == .error) {
      if !take(index) { break }
    }
    for index in before.indices.reversed() where !chosen.contains(index) {
      if !take(index) { break }
    }
    return chosen.sorted().map { before[$0] }
  }
}
