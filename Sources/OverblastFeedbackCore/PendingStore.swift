import Foundation

/// Reports kept on the device after a `429` or with no connection (contract §4: keep the report and
/// offer to send it later, never retry in a loop).
///
/// One JSON file per draft under Application Support, excluded from backups. A draft is tried again
/// once on the next launch (`OverblastFeedback.configure` / `start`) and whenever the app calls
/// `retryPending()`; never on a timer. A draft that is refused for good is deleted, one that is
/// rate limited again stays for the next time, and nothing older than a week or beyond the newest
/// ten is kept, so a device that never gets a connection does not grow a folder of screenshots.
public final class PendingStore: @unchecked Sendable {
  // @unchecked: the only state is `directory`, a constant, and file operations are serialised by
  // `lock`.
  public struct Draft: Codable, Sendable, Equatable {
    public var id: String
    public var savedAt: Date
    public var attempts: Int
    public var payload: FeedbackPayload
  }

  public static let maxDrafts = 10
  public static let maxAge: TimeInterval = 7 * 24 * 3600
  public static let maxAttempts = 5

  public let directory: URL
  private let lock = NSLock()

  public init(directory: URL) {
    self.directory = directory
  }

  /// `Application Support/OverblastFeedback/<bundle id>/pending`: this app's alone, so an unsandboxed
  /// Mac app never sends another app's reports nor wipes them with its own data (`FeedbackStorage`).
  public static func defaultDirectory() -> URL {
    FeedbackStorage.directory("pending")
  }

  private func ensureDirectory() throws {
    let dir = directory
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutable = dir
      try? mutable.setResourceValues(values)
    }
  }

  @discardableResult
  public func save(_ payload: FeedbackPayload, attempts: Int = 1, now: Date = Date()) throws -> Draft {
    let draft = Draft(id: UUID().uuidString.lowercased(), savedAt: now, attempts: attempts, payload: payload)
    try write(draft)
    prune(now: now)
    return draft
  }

  func write(_ draft: Draft) throws {
    lock.lock()
    defer { lock.unlock() }
    try ensureDirectory()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(draft)
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
    options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: url(for: draft.id), options: options)
  }

  /// Oldest first. Unreadable files are deleted: a draft this version cannot read will never send.
  public func all() -> [Draft] {
    lock.lock()
    defer { lock.unlock() }
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    var drafts: [Draft] = []
    for file in files where file.pathExtension == "json" {
      if let data = try? Data(contentsOf: file), let draft = try? decoder.decode(Draft.self, from: data) {
        drafts.append(draft)
      } else {
        try? FileManager.default.removeItem(at: file)
      }
    }
    return drafts.sorted { $0.savedAt < $1.savedAt }
  }

  public func remove(_ id: String) {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: url(for: id))
  }

  public func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: directory)
  }

  /// Drops drafts older than a week, and all but the newest ten.
  public func prune(now: Date = Date()) {
    let drafts = all()
    let stale = drafts.filter { now.timeIntervalSince($0.savedAt) > Self.maxAge }
    let fresh = drafts.filter { now.timeIntervalSince($0.savedAt) <= Self.maxAge }
    for d in stale { remove(d.id) }
    for d in fresh.dropLast(Self.maxDrafts) { remove(d.id) }
  }

  private func url(for id: String) -> URL {
    // The id is ours (a UUID); the filter is belt and braces against a path in a hand-edited file.
    let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return directory.appendingPathComponent(safe).appendingPathExtension("json")
  }

  /// Sends each draft once, oldest first, and stops at the first rate limit or lost connection:
  /// the rest would be refused for the same reason, and trying them is exactly the loop §4 forbids.
  /// Returns how many were delivered.
  public func retry(using send: @Sendable (FeedbackPayload) async throws -> FeedbackReceipt, now: Date = Date()) async -> Int {
    prune(now: now)
    var delivered = 0
    for var draft in all() {
      do {
        _ = try await send(draft.payload)
        remove(draft.id)
        delivered += 1
      } catch let error as FeedbackError {
        if error.wasFiled {
          remove(draft.id)
          delivered += 1
        } else if error.keepsForLater {
          draft.attempts += 1
          if draft.attempts >= Self.maxAttempts {
            remove(draft.id)
          } else {
            try? write(draft)
          }
          break
        } else {
          // Refused for good (bad field, revoked key). Sending it again changes nothing.
          remove(draft.id)
        }
      } catch {
        break
      }
    }
    return delivered
  }
}
