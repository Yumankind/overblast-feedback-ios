import Foundation

/// When the "Something may have gone wrong. Tell us?" pill may appear (contract §3.6). Pure, with the
/// clock passed in, so every rule is tested without waiting; the UI half asks it what to do and tells
/// it what happened.
///
/// - At least 10 seconds after start.
/// - Not while the person is typing (the software keyboard is up, or text changed in a text input in
///   the last five seconds; a field that merely has focus does not count), nor while the report
///   sheet, an alert or the crash offer is showing, nor in the background: it waits, and gives up 30
///   seconds after the error.
/// - At most once per session, at most once per `minHoursBetween` on the device, and after the person
///   closes it twice without reporting, not again for seven days.
/// - Two errors a second apart are one prompt: it is shown a second after the first, never sooner.
public struct ErrorPromptGate: Sendable, Equatable {
  /// What lasts across launches, in this library's own defaults suite.
  public struct Persisted: Codable, Sendable, Equatable {
    public var lastShownAt: Date?
    public var dismissalsWithoutReport: Int
    public var quietUntil: Date?

    public init(lastShownAt: Date? = nil, dismissalsWithoutReport: Int = 0, quietUntil: Date? = nil) {
      self.lastShownAt = lastShownAt
      self.dismissalsWithoutReport = dismissalsWithoutReport
      self.quietUntil = quietUntil
    }
  }

  /// What the screen is doing right now.
  public struct Conditions: Sendable, Equatable {
    public var isForeground: Bool
    /// The software keyboard is on screen.
    public var isKeyboardUp: Bool
    /// The last time text changed in any text input of the app.
    public var lastTextEditAt: Date?
    public var isBlockingUIShowing: Bool

    public init(isForeground: Bool = true, isKeyboardUp: Bool = false, lastTextEditAt: Date? = nil, isBlockingUIShowing: Bool = false) {
      self.isForeground = isForeground
      self.isKeyboardUp = isKeyboardUp
      self.lastTextEditAt = lastTextEditAt
      self.isBlockingUIShowing = isBlockingUIShowing
    }

    /// Typing: the keyboard is up, or text changed in the last five seconds.
    public func isTyping(at now: Date) -> Bool {
      if isKeyboardUp { return true }
      guard let edit = lastTextEditAt else { return false }
      return now.timeIntervalSince(edit) < ErrorPromptGate.typingWindow
    }
  }

  public enum Decision: Sendable, Equatable {
    /// Nothing pending.
    case idle
    /// Ask again at this time.
    case wait(until: Date)
    case show
  }

  public static let startDelay: TimeInterval = 10
  public static let mergeWindow: TimeInterval = 1
  public static let giveUpAfter: TimeInterval = 30
  /// Text changed this recently means the person is still typing.
  public static let typingWindow: TimeInterval = 5
  public static let quietAfterTwoDismissals: TimeInterval = 7 * 24 * 3600

  public let startedAt: Date
  public var settings: FeedbackRemoteConfig.ErrorPrompt
  public var persisted: Persisted
  public private(set) var shownThisSession = false
  /// When the error that is waiting to be shown happened.
  public private(set) var pendingSince: Date?

  public init(startedAt: Date, settings: FeedbackRemoteConfig.ErrorPrompt, persisted: Persisted = Persisted()) {
    self.startedAt = startedAt
    self.settings = settings
    self.persisted = persisted
  }

  /// Whether the device-wide limits allow a prompt at `now`.
  public func allowed(at now: Date) -> Bool {
    guard settings.enabled, !shownThisSession else { return false }
    if let quiet = persisted.quietUntil, now < quiet { return false }
    if let last = persisted.lastShownAt, now.timeIntervalSince(last) < settings.minHoursBetween * 3600 { return false }
    return true
  }

  /// Something went wrong. Returns true when it is now waiting to be shown (false when the kind is
  /// not one the key asks for, the limits say no, or it merged into an error already waiting).
  @discardableResult
  public mutating func noteError(_ kind: FeedbackRemoteConfig.ErrorPrompt.Kind, at now: Date) -> Bool {
    guard settings.on.contains(kind), allowed(at: now) else { return false }
    if let pending = pendingSince, now.timeIntervalSince(pending) <= Self.giveUpAfter { return false }
    pendingSince = now
    return true
  }

  /// What to do at `now`, given the screen.
  public mutating func decide(at now: Date, _ conditions: Conditions) -> Decision {
    guard let pending = pendingSince else { return .idle }
    guard allowed(at: now) else {
      pendingSince = nil
      return .idle
    }
    if now.timeIntervalSince(pending) > Self.giveUpAfter {
      pendingSince = nil
      return .idle
    }
    let earliest = max(startedAt.addingTimeInterval(Self.startDelay), pending.addingTimeInterval(Self.mergeWindow))
    if now < earliest { return .wait(until: earliest) }
    if !conditions.isForeground || conditions.isTyping(at: now) || conditions.isBlockingUIShowing {
      return .wait(until: now.addingTimeInterval(0.5))
    }
    return .show
  }

  public mutating func shown(at now: Date) {
    pendingSince = nil
    shownThisSession = true
    persisted.lastShownAt = now
  }

  /// The person closed it without reporting. The second time, it goes quiet for a week.
  public mutating func dismissed(at now: Date) {
    persisted.dismissalsWithoutReport += 1
    if persisted.dismissalsWithoutReport >= 2 {
      persisted.quietUntil = now.addingTimeInterval(Self.quietAfterTwoDismissals)
      persisted.dismissalsWithoutReport = 0
    }
  }

  /// The person pressed Report: the dismissal count starts again.
  public mutating func reported() {
    persisted.dismissalsWithoutReport = 0
  }
}

/// Where errors are noticed and the gate lives for this launch. The UI half installs a presenter;
/// without one (or with the prompt off) every call here is a cheap no-op.
public final class ErrorPromptCenter: @unchecked Sendable {
  // @unchecked: `gate`, `presenter` and `appHosts` are only touched under `lock`.
  public static let shared = ErrorPromptCenter()
  static let persistedKey = "errorPrompt"

  private let lock = NSLock()
  private var gate: ErrorPromptGate?
  private var appHosts: Set<String> = []
  private var defaults: UserDefaults?
  private var presenter: (@Sendable () -> Void)?

  /// Turns the prompt on for this launch with the key's settings. `onPending` is called (on any
  /// thread) when an error starts waiting; the UI half then asks `decide` until it shows or gives up.
  @_spi(OverblastPlatform)
  public func activate(startedAt: Date, settings: FeedbackRemoteConfig.ErrorPrompt, appHosts: [String], defaults: UserDefaults, onPending: @escaping @Sendable () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    var persisted = ErrorPromptGate.Persisted()
    if let data = defaults.data(forKey: Self.persistedKey), let p = try? JSONDecoder().decode(ErrorPromptGate.Persisted.self, from: data) {
      persisted = p
    }
    if var existing = gate {
      existing.settings = settings
      gate = existing
    } else {
      gate = ErrorPromptGate(startedAt: startedAt, settings: settings, persisted: persisted)
    }
    self.appHosts = Set(appHosts.map { $0.lowercased() })
    self.defaults = defaults
    presenter = onPending
  }

  /// The key or the options turned it off.
  @_spi(OverblastPlatform)
  public func deactivate() {
    lock.lock()
    gate = nil
    presenter = nil
    lock.unlock()
  }

  public func noteError(_ kind: FeedbackRemoteConfig.ErrorPrompt.Kind, at now: Date = Date()) {
    lock.lock()
    let waiting = gate?.noteError(kind, at: now) ?? false
    let presenter = self.presenter
    lock.unlock()
    if waiting { presenter?() }
  }

  /// A request the network recorder saw end: 5xx from one of the app's own hosts is `server_error`,
  /// no answer at all is `network`. 4xx is the person's own input and never counts.
  func noteRequest(host: String?, status: Int, at now: Date = Date()) {
    lock.lock()
    let counts = host.map { appHosts.contains($0.lowercased()) } ?? false
    lock.unlock()
    guard counts else { return }
    if status == 0 { noteError(.network, at: now) } else if (500...599).contains(status) { noteError(.serverError, at: now) }
  }

  @_spi(OverblastPlatform)
  public func decide(at now: Date = Date(), _ conditions: ErrorPromptGate.Conditions) -> ErrorPromptGate.Decision {
    lock.lock()
    defer { lock.unlock() }
    return gate?.decide(at: now, conditions) ?? .idle
  }

  @_spi(OverblastPlatform)
  public func shown(at now: Date = Date()) { update { $0.shown(at: now) } }

  @_spi(OverblastPlatform)
  public func dismissed(at now: Date = Date()) { update { $0.dismissed(at: now) } }

  @_spi(OverblastPlatform)
  public func reported() { update { $0.reported() } }

  private func update(_ change: (inout ErrorPromptGate) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard var g = gate else { return }
    change(&g)
    gate = g
    if let data = try? JSONEncoder().encode(g.persisted) { defaults?.set(data, forKey: Self.persistedKey) }
  }
}
