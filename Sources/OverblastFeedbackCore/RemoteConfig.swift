import Foundation

/// What the key's owner has switched on, read from `GET <endpoint>/config` at start (contract §2.1).
///
/// Before the library has ever had an answer it behaves as the defaults: no device registration, no
/// error prompt, screenshots offered. The integrator's own options can only turn things off.
public struct FeedbackRemoteConfig: Codable, Sendable, Equatable {
  public enum Verification: String, Codable, Sendable {
    case off, flag, require
  }

  public struct ErrorPrompt: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
      case exception
      case serverError = "server_error"
      case network
    }

    public var enabled: Bool
    public var on: [Kind]
    public var minHoursBetween: Double

    public init(enabled: Bool = false, on: [Kind] = [.exception], minHoursBetween: Double = 24) {
      self.enabled = enabled
      self.on = on
      self.minHoursBetween = minHoursBetween
    }

    enum CodingKeys: String, CodingKey { case enabled, on, minHoursBetween }

    /// Tolerant: a kind this version does not know is left out, a missing field is the default.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
      let raw = (try? c.decode([String].self, forKey: .on)) ?? ["exception"]
      on = raw.compactMap(Kind.init(rawValue:))
      minHoursBetween = max(0, (try? c.decode(Double.self, forKey: .minHoursBetween)) ?? 24)
    }
  }

  public var verification: Verification
  public var errorPrompt: ErrorPrompt
  public var screenshots: Bool
  /// The kinds of report the key accepts, in the owner's order; the first is the sheet's default.
  /// `[.bug]` makes it a problem-report key: no category choice, and the sheet is "Report a problem".
  public var categories: [FeedbackCategory]

  public init(verification: Verification = .off, errorPrompt: ErrorPrompt = ErrorPrompt(), screenshots: Bool = true, categories: [FeedbackCategory] = FeedbackCategory.allCases) {
    self.verification = verification
    self.errorPrompt = errorPrompt
    self.screenshots = screenshots
    self.categories = FeedbackRemoteConfig.cleaned(categories)
  }

  enum CodingKeys: String, CodingKey { case verification, errorPrompt, screenshots, categories }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    verification = (try? c.decode(Verification.self, forKey: .verification)) ?? .off
    errorPrompt = (try? c.decode(ErrorPrompt.self, forKey: .errorPrompt)) ?? ErrorPrompt()
    screenshots = (try? c.decode(Bool.self, forKey: .screenshots)) ?? true
    let raw = (try? c.decode([String].self, forKey: .categories)) ?? []
    categories = FeedbackRemoteConfig.cleaned(raw.compactMap(FeedbackCategory.init(rawValue:)))
  }

  /// Duplicates out, order kept; a category this version does not know is left out, and nothing left
  /// (or nothing sent) is all four, which is the default.
  static func cleaned(_ list: [FeedbackCategory]) -> [FeedbackCategory] {
    var seen = Set<FeedbackCategory>()
    let out = list.filter { seen.insert($0).inserted }
    return out.isEmpty ? FeedbackCategory.allCases : out
  }

  /// The defaults, before any answer.
  public static let defaults = FeedbackRemoteConfig()
}

/// The key's answer combined with the integrator's options: the options only ever turn things off.
public struct FeedbackEffectiveConfig: Sendable, Equatable {
  /// Whether the library may register this device (contract §8). Nothing in this version registers
  /// one; it is the gate the attestation work will sit behind.
  public var deviceRegistration: Bool
  public var screenshots: Bool
  /// The error prompt's settings, or nil when it is off.
  public var errorPrompt: FeedbackRemoteConfig.ErrorPrompt?
  /// The categories the key accepts, the first being the default.
  public var categories: [FeedbackCategory] = FeedbackCategory.allCases

  public static func combine(_ remote: FeedbackRemoteConfig, _ options: FeedbackOptions) -> FeedbackEffectiveConfig {
    FeedbackEffectiveConfig(
      deviceRegistration: remote.verification != .off && options.device,
      screenshots: remote.screenshots && options.screenshots,
      errorPrompt: remote.errorPrompt.enabled && options.errorPrompt && !remote.errorPrompt.on.isEmpty ? remote.errorPrompt : nil,
      categories: remote.categories
    )
  }

  /// A key that takes problem reports only: no category choice, "Report a problem".
  public var isProblemReportsOnly: Bool { categories == [.bug] }

  /// The category a sheet opens with: the one asked for when the key takes it, else the key's first.
  public func category(for requested: FeedbackCategory?) -> FeedbackCategory {
    if let requested, categories.contains(requested) { return requested }
    return categories.first ?? .bug
  }

  /// The local refusal for a category the key does not take (the worker's 403
  /// `category_not_accepted`, made before anything is sent).
  public func refusal(for category: FeedbackCategory) -> FeedbackError? {
    guard !categories.contains(category) else { return nil }
    let message = isProblemReportsOnly ? "This app only takes problem reports." : "This app doesn't take that kind of report."
    return .refused(status: 403, code: "category_not_accepted", message: message, field: "category")
  }
}

/// Reads and keeps the key's config: the last answer and its ETag in this library's own
/// `UserDefaults` suite, read again at most every five minutes, the kept answer used when the door
/// cannot be reached.
public final class RemoteConfigStore: @unchecked Sendable {
  // @unchecked: `fetching` and the cache are only touched under `lock`.
  struct Cached: Codable {
    var config: FeedbackRemoteConfig
    var etag: String?
    var fetchedAt: Date
  }

  public static let refreshInterval: TimeInterval = 300
  static let cacheKey = "remoteConfig"

  private let defaults: UserDefaults
  private let lock = NSLock()
  private var fetching = false
  private var cached: Cached?

  public init(defaults: UserDefaults) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.cacheKey) {
      cached = try? JSONDecoder().decode(Cached.self, from: data)
    }
  }

  /// The last answer, or the defaults before there has been one.
  public var current: FeedbackRemoteConfig {
    lock.lock()
    defer { lock.unlock() }
    return cached?.config ?? .defaults
  }

  /// Reads the config when the kept answer is older than five minutes (or there is none). A failure
  /// leaves the kept answer as it is.
  public func refreshIfStale(client: FeedbackClient, now: Date = Date()) async {
    guard let etag = beginFetch(now: now) else { return }
    let result = try? await client.fetchConfig(etag: etag.value)
    finishFetch(result, now: now)
  }

  /// Nil when no read is due (or one is already running); otherwise the ETag to send.
  func beginFetch(now: Date) -> (value: String?, Void)? {
    lock.lock()
    defer { lock.unlock() }
    if fetching || (cached.map { now.timeIntervalSince($0.fetchedAt) < Self.refreshInterval } ?? false) { return nil }
    fetching = true
    return (cached?.etag, ())
  }

  /// A failure (nil) leaves the kept answer as it is.
  func finishFetch(_ result: FeedbackClient.ConfigAnswer?, now: Date) {
    lock.lock()
    defer { lock.unlock() }
    fetching = false
    switch result {
    case .some(.notModified):
      cached?.fetchedAt = now
    case .some(.config(let config, let newTag)):
      cached = Cached(config: config, etag: newTag, fetchedAt: now)
    case .none:
      return
    }
    if let cached, let data = try? JSONEncoder().encode(cached) {
      defaults.set(data, forKey: Self.cacheKey)
    }
  }
}

extension FeedbackClient {
  public enum ConfigAnswer: Sendable {
    case config(FeedbackRemoteConfig, etag: String?)
    case notModified
  }

  /// `GET <endpoint>/config` (contract §2.1).
  public func fetchConfig(etag: String?) async throws -> ConfigAnswer {
    var request = URLRequest(url: endpoint.appendingPathComponent("config"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(key, forHTTPHeaderField: Self.keyHeader)
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw Self.mapTransport(error)
    }
    guard let http = response as? HTTPURLResponse else { throw FeedbackError.offline(message: "The feedback service did not answer.") }
    if http.statusCode == 304 { return .notModified }
    guard (200..<300).contains(http.statusCode) else {
      throw FeedbackError.refused(status: http.statusCode, code: "config_unavailable", message: "The feedback settings could not be read.", field: nil)
    }
    let config = try JSONDecoder().decode(FeedbackRemoteConfig.self, from: data)
    return .config(config, etag: http.value(forHTTPHeaderField: "ETag"))
  }
}
