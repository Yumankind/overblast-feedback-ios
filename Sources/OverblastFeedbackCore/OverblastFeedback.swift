import Foundation

/// What the library does beyond the required. Every default is the conservative one.
public struct FeedbackOptions: Sendable, Equatable {
  /// Open the report sheet when the device is shaken. `OverblastFeedback.isShakeEnabled` switches it
  /// at run time.
  ///
  /// On by default on an iPhone or iPad, and nothing else: a Mac and Apple Vision Pro deliver no
  /// shake to an app, so there it is false and ignored, and the sheet opens only from
  /// `OverblastFeedback.present()` (button mode). False on an iPhone or iPad is button mode too.
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
  /// At the launch after the app closed unexpectedly, ask once whether to send a report about it
  /// (contract §3.4). The previous session's logs are kept either way.
  public var offerReportAfterCrash: Bool
  /// The options below can only turn off what the key's owner has on (contract §2.1).
  /// False: never register this device, whatever the key's `verification` says.
  public var device: Bool
  /// False: never offer a screenshot, even when the key allows one.
  public var screenshots: Bool
  /// False: never show the error prompt, even when the key enables it.
  public var errorPrompt: Bool
  /// The app's own API hosts (`api.example.com`). A request to one of them answered 500 to 599, or
  /// never answered, can set off the error prompt when the key asks for `server_error` or `network`.
  /// Seen only through the network recorder (`recordNetwork`).
  public var appHosts: [String]
  /// The report UI's brand: accent colour, font family, corner radius. The default is the app's own
  /// tint and the system font.
  public var theme: FeedbackTheme
  /// The sentences the sheet says after Send, for your own wording or language.
  public var messages: FeedbackMessages

  public init(
    shakeToReport: Bool = DeviceInfo.deliversShake,
    captureOSLog: Bool = true,
    osLogWindow: TimeInterval = 300,
    includeLogs: Bool = true,
    recordNetwork: Bool = false,
    extra: [String: String] = [:],
    retryPendingOnStart: Bool = true,
    offerReportAfterCrash: Bool = true,
    device: Bool = true,
    screenshots: Bool = true,
    errorPrompt: Bool = true,
    appHosts: [String] = [],
    theme: FeedbackTheme = .system,
    messages: FeedbackMessages = FeedbackMessages()
  ) {
    self.shakeToReport = shakeToReport && DeviceInfo.deliversShake
    self.captureOSLog = captureOSLog
    self.osLogWindow = osLogWindow
    self.includeLogs = includeLogs
    self.recordNetwork = recordNetwork
    self.extra = extra
    self.retryPendingOnStart = retryPendingOnStart
    self.offerReportAfterCrash = offerReportAfterCrash
    self.device = device
    self.screenshots = screenshots
    self.errorPrompt = errorPrompt
    self.appHosts = appHosts
    self.theme = theme
    self.messages = messages
  }
}

/// The sheet's sentences after Send. The service's own refusal sentences are shown as it wrote them.
public struct FeedbackMessages: Sendable, Equatable {
  /// The usual thank-you.
  public var sent: String
  /// When the report joined an issue the team already has (`FeedbackReceipt.known`).
  public var sentKnownIssue: String

  public init(sent: String = "Sent. Thank you.", sentKnownIssue: String = "Thanks. We already know about this one and we're on it.") {
    self.sent = sent
    self.sentKnownIssue = sentKnownIssue
  }

  /// The thank-you for this receipt.
  public func thankYou(for receipt: FeedbackReceipt) -> String {
    receipt.known ? sentKnownIssue : sent
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
/// In an app, call `OverblastFeedback.start(key:)` from the `OverblastFeedback` module (iOS, iPadOS,
/// visionOS and macOS), which does everything `configure` does, tells the core which screen is
/// showing, and on an iPhone or iPad installs shake-to-report. `configure` is the platform-neutral
/// half, for a command-line tool, an extension without UI, or a test.
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
    let suite = defaults ?? FeedbackStorage.defaults()
    let config = Engine.Config(
      client: FeedbackClient(endpoint: endpoint, key: key, session: session),
      options: options,
      store: store ?? PendingStore(directory: PendingStore.defaultDirectory()),
      deviceId: DeviceInfo.deviceId(defaults: suite),
      remote: RemoteConfigStore(defaults: suite),
      defaults: Engine.SharedDefaults(value: suite)
    )
    Engine.shared.set(config)
    if let reporter { Engine.shared.reporter = reporter.isEmpty ? nil : reporter }
    if options.recordNetwork { recordNetwork() }
    if options.retryPendingOnStart {
      Task.detached(priority: .utility) { await retryPending() }
    }
  }

  /// True where a shake reaches the app: an iPhone or iPad. False on a Mac, on visionOS, and for an
  /// iPhone or iPad app running on a Mac or on Apple Vision Pro, where the report sheet opens only
  /// from `present()` (button mode).
  public static var isShakeAvailable: Bool { DeviceInfo.deliversShake }

  /// What the key's owner has on (the last answer from the config door, or the defaults before the
  /// first), combined with your options, which can only turn things off.
  public static var effectiveConfig: FeedbackEffectiveConfig {
    let remote = Engine.shared.config?.remote.current ?? .defaults
    return FeedbackEffectiveConfig.combine(remote, options)
  }

  /// Reads `GET <endpoint>/config` when the kept answer is older than five minutes. `start` calls
  /// it; a long-lived app may call it again (on coming to the foreground, say).
  public static func refreshRemoteConfig() async {
    guard let config = Engine.shared.config else { return }
    await config.remote.refreshIfStale(client: config.client)
  }

  @_spi(OverblastPlatform)
  public static var sharedDefaults: UserDefaults? { Engine.shared.config?.defaults.value }

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

  /// The buffer `log` writes into (contract §3.5): repeats collapsed, at most 50 lines a second (200
  /// for warnings and errors), 2 MB and 20,000 lines, debug and info evicted before warnings and
  /// errors, each kept line redacted as it enters.
  public static let logBuffer = FeedbackLogBuffer()

  /// Records a line for the next report. Cheap and thread-safe; works before `start`.
  ///
  /// `unexpected: true` on an error says it is one the app did not expect and could not handle (the
  /// Swift equivalent of an uncaught exception): it can set off the error prompt when the key asks
  /// for `exception` (contract §3.6). An uncaught Objective-C exception cannot, because the app is
  /// ending by then.
  public static func log(_ level: FeedbackLogLevel, _ message: String, source: String? = "app", unexpected: Bool = false) {
    // A cheap cut so a pathological line cannot cost megabytes before the buffer's own cut.
    let msg = message.utf16.count > FeedbackLimits.logMessage * 2 ? String(message.prefix(FeedbackLimits.logMessage)) : message
    if logBuffer.append(.now(level, msg, src: source)) {
      Engine.shared.session?.noteLog(level)
    }
    if unexpected, level == .error {
      ErrorPromptCenter.shared.noteError(.exception)
    }
  }

  public static func debug(_ message: String) { log(.debug, message) }
  public static func info(_ message: String) { log(.info, message) }
  public static func warn(_ message: String) { log(.warn, message) }
  public static func error(_ message: String, unexpected: Bool = false) { log(.error, message, unexpected: unexpected) }

  /// Everything the buffer holds before `until`, merged with this process's unified log (when
  /// `captureOSLog` is on) after the unified log's own lines have been filtered to the app's and put
  /// through the same intake rules. Oldest first; already redacted. Call it off the main thread.
  ///
  /// `until` is the moment the report was opened: the sheets pass the moment they appeared, so the
  /// lines logged about the sheet itself, by the app or by UIKit and AppKit, are never collected.
  public static func collectLogs(until: Date? = nil) async -> [FeedbackLogEntry] {
    let opts = options
    // Lines from the same millisecond as `until` are still in.
    let cutoff = until.map { millis($0) + 1 }
    let own = logBuffer.snapshot(until: cutoff)
    guard opts.captureOSLog else { return own }
    let window = opts.osLogWindow
    let system = await Task.detached(priority: .utility) { () -> [FeedbackLogEntry] in
      let lines = OSLogCollector.recent(window: window, until: until, limit: FeedbackLogBuffer.Limits().maxLines)
      let intake = FeedbackLogBuffer()
      intake.append(contentsOf: lines)
      return intake.snapshot()
    }.value
    return OSLogCollector.merge(own, system, limit: FeedbackLogBuffer.Limits().maxLines * 2)
  }

  static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  // MARK: Sessions (contract §3.4)

  /// Opens this launch's session: the log buffer is kept on disk from now on, the uncaught-exception
  /// handler is installed (chained to any before it), and the previous session is returned when it
  /// never closed. The UI half calls it from `start`, because only it hears the app go to the
  /// background, which is what closes a session.
  @_spi(OverblastPlatform)
  @discardableResult
  public static func beginSession(store: SessionStore = SessionStore(directory: SessionStore.defaultDirectory())) -> PreviousSession? {
    if let existing = Engine.shared.session { return existing.store.previous }
    let recorder = SessionRecorder(store: store, buffer: logBuffer)
    let previous = store.begin()
    Engine.shared.session = recorder
    ExceptionHandler.install()
    // Whatever was logged before `start` belongs to this session too.
    if logBuffer.count > 0 { recorder.noteLog(.info) }
    return previous
  }

  /// The app went to the background or is terminating: the log is written and the session marked
  /// closed, so the next launch does not take it for a crash.
  @_spi(OverblastPlatform)
  public static func closeSession() {
    guard let recorder = Engine.shared.session else { return }
    recorder.flushNow()
    recorder.store.close()
  }

  /// The app is in the foreground again.
  @_spi(OverblastPlatform)
  public static func reopenSession() {
    Engine.shared.session?.store.reopen()
  }

  /// MetricKit's newest crash, stored until a report about the previous session is sent.
  @_spi(OverblastPlatform)
  public static func recordMetricCrash(_ record: MetricCrashRecord) {
    Engine.shared.session?.store.recordMetricCrash(record)
  }

  /// The session before this launch, when it ended unexpectedly and nobody has answered for it yet.
  public static var previousSession: PreviousSession? { Engine.shared.session?.store.previous }

  /// What a report about the previous session would carry as `crash`, decided now.
  public static var previousSessionCrash: FeedbackCrash? { Engine.shared.session?.store.crashForPrevious() }

  /// Done with the previous session (reported, or declined): the offer is not made again.
  public static func forgetPreviousSession() {
    Engine.shared.session?.store.forgetPrevious()
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
  ///
  /// `logs` nil collects them (the excerpt as `logs`, everything as `logFile`); pass `[]` to send
  /// none, or the entries to use, such as the previous session's. `openedAt` nil is now.
  public static func buildPayload(
    message: String,
    category: FeedbackCategory = .bug,
    reporter: FeedbackReporter? = nil,
    element: FeedbackElement? = nil,
    screenshot: FeedbackScreenshot? = nil,
    logs: [FeedbackLogEntry]? = nil,
    includeNetwork: Bool = true,
    extra: [String: String] = [:],
    trigger: FeedbackTrigger = .api,
    openedAt: Date? = nil,
    crash: FeedbackCrash? = nil
  ) async throws -> FeedbackPayload {
    guard let config = Engine.shared.config else { throw FeedbackError.notStarted }
    let opened = openedAt ?? Date()
    var mergedExtra = config.options.extra
    for (k, v) in extra { mergedExtra[k] = v }
    var context = DeviceInfo.baseContext(deviceId: config.deviceId, extra: mergedExtra)
    if let provider = Engine.shared.platformContext {
      let platform = await provider()
      context.screen = platform.screen
      context.title = platform.title
      context.viewport = platform.viewport
    }
    context.openedAt = millis(opened)
    context.trigger = trigger
    let collected: [FeedbackLogEntry]
    if !config.options.includeLogs {
      collected = []
    } else if let logs {
      collected = logs
    } else {
      collected = await collectLogs(until: opened)
    }
    var payload = FeedbackPayload(
      message: message,
      category: crash == nil ? category : .bug,
      reporter: merge(Engine.shared.reporter, reporter),
      context: context,
      element: element,
      screenshot: screenshot,
      // The excerpt favours the errors of the two minutes before the report; for a report about a
      // crashed session, the two minutes before its last line.
      logs: collected.isEmpty ? nil : LogSelection.excerpt(collected, openedAt: (crash == nil ? millis(opened) : (collected.map(\.t).max() ?? 0)) + 1),
      network: includeNetwork ? networkEntries() : nil,
      crash: crash
    )
    // The file only when the excerpt could not hold every line (contract §3.5).
    if collected.count > (payload.logs?.count ?? 0) {
      payload.logFile = LogFileBuilder.build(collected, budget: logFileBudget(for: payload))
    }
    return payload
  }

  /// What is left of the 8 MB body for the log file, in compressed bytes, once everything else is
  /// in: the log file shrinks first (contract §3.5), at most 4 MB. A 5 MB screenshot (6.7 MB as
  /// base64) and a full excerpt still leave room, so the screenshot never has to.
  static func logFileBudget(for payload: FeedbackPayload) -> Int {
    let sanitized = (try? payload.sanitized()) ?? payload
    let room = FeedbackLimits.bodyBytes - sanitized.encodedSize() - 4096
    return max(0, min(LogFileBuilder.maxBytes, room / 4 * 3))
  }

  /// Sends a report without any UI.
  ///
  /// On a `429` or with no connection the report is kept on the device (unless `keepForLater` is
  /// false) and the error is still thrown, so the caller can say so. `logs` nil collects them;
  /// pass `[]` to send none. `trigger` and `openedAt` say what opened the report and when (now, by
  /// default); `crash` is for a report about the previous session.
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
    trigger: FeedbackTrigger = .api,
    openedAt: Date? = nil,
    crash: FeedbackCrash? = nil,
    keepForLater: Bool = true
  ) async throws -> FeedbackReceipt {
    let payload = try await buildPayload(
      message: message, category: category, reporter: reporter, element: element,
      screenshot: screenshot, logs: logs, includeNetwork: includeNetwork, extra: extra,
      trigger: trigger, openedAt: openedAt, crash: crash
    )
    return try await send(payload, keepForLater: keepForLater)
  }

  /// Sends a payload you built (it is sanitized first), keeping it on a 429 or with no connection.
  @discardableResult
  public static func send(_ payload: FeedbackPayload, keepForLater: Bool = true) async throws -> FeedbackReceipt {
    guard let config = Engine.shared.config else { throw FeedbackError.notStarted }
    // A category the key does not take is refused here, as the worker would (contract §2), and not
    // kept for later: it would be refused again.
    if let refusal = effectiveConfig.refusal(for: payload.category) { throw refusal }
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

  // MARK: What the sheet's Send came to

  /// Called once for every Send pressed in the report sheet, however the sheet was opened: shake,
  /// `OverblastFeedbackButton`, the Help menu item, the error prompt, the offer after a crash, or
  /// `present(...)` (whose own `onResult` is called first). On the main actor, after the answer and
  /// before the sheet shows its confirmation or its error. For logging the report id, or a failure.
  ///
  /// - `.success(receipt)`: filed; `receipt.id` is the report (`fbr_...`), `receipt.taskId` the task,
  ///   `receipt.conversationId` the email conversation when there is one, and `receipt.known` true
  ///   when it joined an issue the team already has.
  /// - `.failure(error)`: `error.code` is the service's refusal code where it sent one
  ///   (`invalid_field`, `unknown_key`, `category_not_accepted`, `rate_limited`, ...). Two failures
  ///   are not lost reports: `error.keepsForLater` (a rate limit or no connection; the report is kept
  ///   and sent later) and `error.wasFiled` (`storage_full`: filed without its screenshot).
  ///
  /// A refusal leaves the sheet open, so pressing Send again is a second Send and a second call.
  /// Cancelling is not a result and is never reported: nothing was sent, and an app that wants to
  /// know the sheet closed can watch `isPresenting`. `report(...)` and `send(_:)` return or throw
  /// their result directly and do not call this.
  @MainActor
  public static var onReportResult: (@MainActor (FeedbackResult) -> Void)?

  /// The sheets' one way to hand a Send's outcome out: the caller's own `onResult`, then the
  /// app-wide `onReportResult`.
  @_spi(OverblastPlatform)
  @MainActor
  public static func deliverReportResult(_ result: FeedbackResult, to handler: (@MainActor (FeedbackResult) -> Void)?) {
    handler?(result)
    onReportResult?(result)
  }

  /// What `report(...)` threw, as the `FeedbackError` a `FeedbackResult` carries. Everything it throws
  /// is one already; anything else (which this version never throws) becomes a report that could not
  /// be prepared, which is how the sheets treat it: shown, not kept, not filed.
  @_spi(OverblastPlatform)
  public static func feedbackError(from error: any Error) -> FeedbackError {
    (error as? FeedbackError) ?? .invalidReport(field: "body", message: error.localizedDescription)
  }

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
  // @unchecked: `_config`, `_reporter`, `_platformContext`, `_session` and `retrying` are only
  // touched under `lock`.
  struct Config: Sendable {
    var client: FeedbackClient
    var options: FeedbackOptions
    var store: PendingStore
    var deviceId: String
    var remote: RemoteConfigStore
    var defaults: SharedDefaults
  }

  /// `UserDefaults` is documented as thread-safe but not marked `Sendable`.
  struct SharedDefaults: @unchecked Sendable {
    let value: UserDefaults
  }

  static let shared = Engine()
  private let lock = NSLock()
  private var _config: Config?
  private var _reporter: FeedbackReporter?
  private var _platformContext: (@Sendable () async -> PlatformContext)?
  private var retrying = false
  private var _session: SessionRecorder?

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

  var session: SessionRecorder? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _session
    }
    set {
      lock.lock()
      _session = newValue
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
