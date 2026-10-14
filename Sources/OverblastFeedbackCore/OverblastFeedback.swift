import Foundation

/// What the library does beyond the required. Every default is the conservative one.
public struct FeedbackOptions: Sendable, Equatable {
  /// Open the report sheet when the device is shaken (iOS). `OverblastFeedback.isShakeEnabled`
  /// switches it at run time.
  public var shakeToReport: Bool
  /// Merge the last `osLogWindow` seconds of this process's unified log (`Logger`, `os_log`,
  /// `NSLog`) into the report's logs.
  public var captureOSLog: Bool
  public var osLogWindow: TimeInterval
  /// Send logs at all. Off sends no `logs` field.
  public var includeLogs: Bool
  /// Register `OverblastNetworkRecorder` for `URLSession.shared` at start. Off by default: it sits
  /// in the path of the app's requests, so it should be a decision.
  public var recordNetwork: Bool
  /// Added to every report's `context.extra` (≤ 20 keys, values ≤ 200).
  public var extra: [String: String]
  /// Try the reports kept after a 429 or with no connection once, at start.
  public var retryPendingOnStart: Bool

  public init(
    shakeToReport: Bool = true,
    captureOSLog: Bool = true,
    osLogWindow: TimeInterval = 300,
    includeLogs: Bool = true,
    recordNetwork: Bool = false,
    extra: [String: String] = [:],
    retryPendingOnStart: Bool = true
  ) {
    self.shakeToReport = shakeToReport
    self.captureOSLog = captureOSLog
    self.osLogWindow = osLogWindow
    self.includeLogs = includeLogs
    self.recordNetwork = recordNetwork
    self.extra = extra
    self.retryPendingOnStart = retryPendingOnStart
  }
}

/// What the UI half knows that the core does not: which screen is showing, and its size.
@_spi(OverblastPlatform)
public struct PlatformContext: Sendable {
  public var screen: String?
  public var title: String?
  public var viewport: FeedbackViewport?

  public init(screen: String? = nil, title: String? = nil, viewport: FeedbackViewport? = nil) {
    self.screen = screen
    self.title = title
    self.viewport = viewport
  }
}

/// Feedback reports into an Overblast workspace.
///
/// In an iOS app, call `OverblastFeedback.start(key:)` from the `OverblastFeedback` module, which
/// does everything `configure` does and also installs shake-to-report. `configure` is the
/// platform-neutral half, for a Mac target or a test.
public enum OverblastFeedback {
  // MARK: Setup

  /// Sets the key, the endpoint and the reporter, and tries any kept reports once.
  public static func configure(
    key: String,
    endpoint: URL = FeedbackClient.defaultEndpoint,
    reporter: FeedbackReporter? = nil,
    options: FeedbackOptions = FeedbackOptions()
  ) {
    configure(key: key, endpoint: endpoint, reporter: reporter, options: options, session: nil, store: nil, defaults: nil)
  }

  static func configure(
    key: String,
    endpoint: URL,
    reporter: FeedbackReporter?,
    options: FeedbackOptions,
    session: URLSession?,
    store: PendingStore?,
    defaults: UserDefaults?
  ) {
    assert(key.hasPrefix("obfk_"), "OverblastFeedback: a feedback key starts with obfk_. Copy it from the console's Feedback keys page.")
    let config = Engine.Config(
      client: FeedbackClient(endpoint: endpoint, key: key, session: session),
      options: options,
      store: store ?? PendingStore(directory: PendingStore.defaultDirectory()),
      deviceId: DeviceInfo.deviceId(defaults: defaults)
    )
    Engine.shared.set(config)
    if let reporter { Engine.shared.reporter = reporter.isEmpty ? nil : reporter }
    if options.recordNetwork { recordNetwork() }
    if options.retryPendingOnStart {
      Task.detached(priority: .utility) { await retryPending() }
    }
  }

  /// True once `configure` (or `start`) has run.
  public static var isConfigured: Bool { Engine.shared.config != nil }

  /// The person using the app, as the integrator knows them. Call it after sign-in, and with nils
  /// after sign-out. With an `email`, the sheet does not ask for one.
  public static func setReporter(email: String? = nil, name: String? = nil, accountRef: String? = nil) {
    let r = FeedbackReporter(email: email, name: name, accountRef: accountRef)
    Engine.shared.reporter = r.isEmpty ? nil : r
  }

  /// Works before `start` too: a reporter set first is kept.
  public static var reporter: FeedbackReporter? { Engine.shared.reporter }
  public static var options: FeedbackOptions { Engine.shared.config?.options ?? FeedbackOptions() }

  /// Replaces `context.extra` for later reports.
  public static func setExtra(_ extra: [String: String]) {
    Engine.shared.update { $0.options.extra = extra }
  }

  // MARK: Logs

  /// The ring buffer `log` writes into: the last 500 lines, oldest dropped first.
  public static let logBuffer = RingBuffer<FeedbackLogEntry>(capacity: FeedbackLimits.logEntries)

  /// Records a line for the next report. Cheap and thread-safe; works before `start`. Lines are
  /// redacted when a report is built, not here.
  public static func log(_ level: FeedbackLogLevel, _ message: String, source: String? = "app") {
    // A cheap cut so a pathological line cannot hold megabytes in the ring.
    let msg = message.utf16.count > FeedbackLimits.logMessage * 2 ? String(message.prefix(FeedbackLimits.logMessage)) : message
    logBuffer.append(.now(level, msg, src: source))
  }

  public static func debug(_ message: String) { log(.debug, message) }
  public static func info(_ message: String) { log(.info, message) }
  public static func warn(_ message: String) { log(.warn, message) }
  public static func error(_ message: String) { log(.error, message) }

  /// The buffer merged with this process's unified log (when `captureOSLog` is on), newest 500,
  /// oldest first. Not yet redacted; `report` redacts. Call it off the main thread.
  public static func collectLogs() async -> [FeedbackLogEntry] {
    let opts = options
    let own = logBuffer.snapshot()
    guard opts.captureOSLog else { return own }
    let window = opts.osLogWindow
    let system = await Task.detached(priority: .utility) { OSLogCollector.recent(window: window) }.value
    return OSLogCollector.merge(own, system)
  }

  // MARK: Network

  /// Registers `OverblastNetworkRecorder` for `URLSession.shared`. For your own sessions use
  /// `OverblastNetworkRecorder.install(in:)` on their configuration.
  public static func recordNetwork() {
    _ = registerRecorderOnce
  }

  private static let registerRecorderOnce: Void = {
    URLProtocol.registerClass(OverblastNetworkRecorder.self)
  }()

  public static func networkEntries() -> [FeedbackNetworkEntry] {
    OverblastNetworkRecorder.entries.snapshot()
  }

  // MARK: Reports

  /// The UI half's way to add the screen and the viewport to the context.
  @_spi(OverblastPlatform)
  public static func setPlatformContextProvider(_ provider: (@Sendable () async -> PlatformContext)?) {
    Engine.shared.platformContext = provider
  }

  /// Builds the payload a `report` call would send, before limits are applied.
  public static func buildPayload(
    message: String,
    category: FeedbackCategory = .bug,
    reporter: FeedbackReporter? = nil,
    element: FeedbackElement? = nil,
    screenshot: FeedbackScreenshot? = nil,
    logs: [FeedbackLogEntry]? = nil,
    includeNetwork: Bool = true,
    extra: [String: String] = [:]
  ) async throws -> FeedbackPayload {
    guard let config = Engine.shared.config else { throw FeedbackError.notStarted }
    var mergedExtra = config.options.extra
    for (k, v) in extra { mergedExtra[k] = v }
    var context = DeviceInfo.baseContext(deviceId: config.deviceId, extra: mergedExtra)
    if let provider = Engine.shared.platformContext {
      let platform = await provider()
      context.screen = platform.screen
      context.title = platform.title
      context.viewport = platform.viewport
    }
    let collected: [FeedbackLogEntry]?
    if !config.options.includeLogs {
      collected = nil
    } else if let logs {
      collected = logs
    } else {
      collected = await collectLogs()
    }
    return FeedbackPayload(
      message: message,
      category: category,
      reporter: merge(Engine.shared.reporter, reporter),
      context: context,
      element: element,
      screenshot: screenshot,
      logs: collected,
      network: includeNetwork ? networkEntries() : nil
    )
  }

  /// Sends a report without any UI.
  ///
  /// On a `429` or with no connection the report is kept on the device (unless `keepForLater` is
  /// false) and the error is still thrown, so the caller can say so. `logs` nil collects them;
  /// pass `[]` to send none.
  @discardableResult
  public static func report(
    message: String,
    category: FeedbackCategory = .bug,
    reporter: FeedbackReporter? = nil,
    element: FeedbackElement? = nil,
    screenshot: FeedbackScreenshot? = nil,
    logs: [FeedbackLogEntry]? = nil,
    includeNetwork: Bool = true,
    extra: [String: String] = [:],
    keepForLater: Bool = true
  ) async throws -> FeedbackReceipt {
    let payload = try await buildPayload(
      message: message, category: category, reporter: reporter, element: element,
      screenshot: screenshot, logs: logs, includeNetwork: includeNetwork, extra: extra
    )
    return try await send(payload, keepForLater: keepForLater)
  }

  /// Sends a payload you built (it is sanitized first), keeping it on a 429 or with no connection.
  @discardableResult
  public static func send(_ payload: FeedbackPayload, keepForLater: Bool = true) async throws -> FeedbackReceipt {
    guard let config = Engine.shared.config else { throw FeedbackError.notStarted }
    let clean = try payload.sanitized()
    do {
      return try await config.client.send(clean)
    } catch let error as FeedbackError {
      if error.keepsForLater, keepForLater {
        _ = try? config.store.save(clean)
      }
      throw error
    }
  }

  /// Sends the kept reports once each, oldest first, stopping at the first that is rate limited or
  /// cannot connect. Returns how many were delivered. Safe to call at any time; a call while another
  /// is running returns 0 at once.
  @discardableResult
  public static func retryPending() async -> Int {
    guard let config = Engine.shared.config, Engine.shared.beginRetry() else { return 0 }
    defer { Engine.shared.endRetry() }
    let client = config.client
    return await config.store.retry(using: { try await client.send($0) })
  }

  /// How many reports are waiting to be sent.
  public static var pendingCount: Int { Engine.shared.config?.store.all().count ?? 0 }

  static func merge(_ base: FeedbackReporter?, _ override: FeedbackReporter?) -> FeedbackReporter? {
    guard let override else { return base }
    let r = FeedbackReporter(
      email: override.email ?? base?.email,
      name: override.name ?? base?.name,
      accountRef: override.accountRef ?? base?.accountRef
    )
    return r.isEmpty ? nil : r
  }
}

/// The library's state, behind one lock.
final class Engine: @unchecked Sendable {
  // @unchecked: `_config`, `_reporter`, `_platformContext` and `retrying` are only touched under
  // `lock`.
  struct Config: Sendable {
    var client: FeedbackClient
    var options: FeedbackOptions
    var store: PendingStore
    var deviceId: String
  }

  static let shared = Engine()
  private let lock = NSLock()
  private var _config: Config?
  private var _reporter: FeedbackReporter?
  private var _platformContext: (@Sendable () async -> PlatformContext)?
  private var retrying = false

  var config: Config? {
    lock.lock()
    defer { lock.unlock() }
    return _config
  }

  func set(_ config: Config?) {
    lock.lock()
    _config = config
    lock.unlock()
  }

  func update(_ change: (inout Config) -> Void) {
    lock.lock()
    if var c = _config {
      change(&c)
      _config = c
    }
    lock.unlock()
  }

  var reporter: FeedbackReporter? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _reporter
    }
    set {
      lock.lock()
      _reporter = newValue
      lock.unlock()
    }
  }

  var platformContext: (@Sendable () async -> PlatformContext)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _platformContext
    }
    set {
      lock.lock()
      _platformContext = newValue
      lock.unlock()
    }
  }

  func beginRetry() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if retrying { return false }
    retrying = true
    return true
  }

  func endRetry() {
    lock.lock()
    retrying = false
    lock.unlock()
  }
}
