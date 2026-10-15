import Foundation

/// Where the library keeps what it keeps: the install id (and the key's settings, and the error
/// prompt's memory) in a `UserDefaults` suite, and the session files and the kept reports in
/// Application Support. One place per app, named after the app's bundle id.
///
/// WHY PER APP. Up to 0.2.0 the suite was `network.deployd.overblast-feedback` and the folders were
/// `Application Support/OverblastFeedback/session` and `.../pending`, the same names in every app. On
/// iOS, iPadOS, visionOS and in a sandboxed Mac app that is harmless, because the system already
/// gives each app its own container. An unsandboxed Mac app has no container: those names resolve to
/// `~/Library/Preferences/network.deployd.overblast-feedback.plist` and `~/Library/Application
/// Support/OverblastFeedback`, shared by every unsandboxed app on the Mac that uses the library. One
/// app then read another's unclosed session as its own crash (Deskslap offered "The app closed
/// unexpectedly" on its very first launch), sent another app's kept reports with its own key, and
/// an app's data reset wiped the others' kept reports. So the names now carry the bundle id, on every
/// platform, so one rule holds everywhere.
///
/// THE MOVE FROM 0.2.0, once (`migrate`). Where the old location was private to the app anyway (iOS,
/// iPadOS, visionOS, a sandboxed Mac app) everything in it is this app's: the install id, the kept
/// reports and an unfinished session are carried over, so an existing install keeps its device id and
/// a crash just before the update is still offered, and the old entries are then removed. Where it was
/// shared (an unsandboxed Mac app) nothing in it can be attributed to this app, so nothing is adopted:
/// the app starts fresh in its own place, and the shared entries are left alone for whichever apps
/// still run 0.2.0.
public enum FeedbackStorage {
  /// The suite every app used up to 0.2.0.
  public static let legacyDefaultsSuite = "network.deployd.overblast-feedback"
  static let folderName = "OverblastFeedback"
  /// The two folders 0.2.0 kept directly under `OverblastFeedback`, and which a host id must
  /// therefore never be named.
  static let legacyFolders = ["session", "pending"]

  // MARK: Names

  /// This app's name for its store: the main bundle's identifier, or, for a host without one (a
  /// command-line tool), the executable's name.
  public static let hostIdentifier: String = hostIdentifier(
    bundleIdentifier: Bundle.main.bundleIdentifier,
    processName: ProcessInfo.processInfo.processName
  )

  /// Pure, so the fallbacks are tested. The result is used as a folder name and in a defaults suite
  /// name, so anything outside `[A-Za-z0-9._-]` becomes `_`; it is never empty, never `.` or `..`, and
  /// never one of 0.2.0's own folder names, which sit beside it.
  static func hostIdentifier(bundleIdentifier: String?, processName: String) -> String {
    let raw = [bundleIdentifier, processName]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
    var safe = String(raw.map { c -> Character in
      c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_") ? c : "_"
    })
    if safe.count > 200 { safe = String(safe.prefix(200)) }
    if safe.isEmpty || safe.allSatisfy({ $0 == "." }) { return "unknown-host" }
    if legacyFolders.contains(safe) { return "host-" + safe }
    return safe
  }

  /// `network.deployd.overblast-feedback.<host>`. (A suite may not be named the app's own bundle id;
  /// the prefix keeps it clear of that rule.)
  public static var defaultsSuite: String { defaultsSuite(host: hostIdentifier) }

  static func defaultsSuite(host: String) -> String { "\(legacyDefaultsSuite).\(host)" }

  /// `Application Support/OverblastFeedback/<host>`, under which `session` and `pending` live.
  public static var rootDirectory: URL {
    prepare()
    return rootDirectory(base: applicationSupport, host: hostIdentifier)
  }

  static func rootDirectory(base: URL, host: String) -> URL {
    legacyRoot(base: base).appendingPathComponent(host, isDirectory: true)
  }

  static func legacyRoot(base: URL) -> URL {
    base.appendingPathComponent(folderName, isDirectory: true)
  }

  /// One of the folders under this app's root: `session` or `pending`.
  static func directory(_ name: String) -> URL {
    rootDirectory.appendingPathComponent(name, isDirectory: true)
  }

  /// This app's suite, after the move from 0.2.0 has had its chance to run.
  public static func defaults() -> UserDefaults {
    prepare()
    return UserDefaults(suiteName: defaultsSuite) ?? .standard
  }

  static var applicationSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
  }

  // MARK: Sandboxing

  /// True when 0.2.0's location was this app's alone: always on iOS, iPadOS and visionOS (and for an
  /// iPhone or iPad app running on a Mac or on Apple Vision Pro, which is always in a container); on
  /// macOS and Mac Catalyst only inside the App Sandbox.
  public static var legacyLocationIsPrivate: Bool {
    #if os(macOS) || targetEnvironment(macCatalyst)
    return isSandboxed(environment: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    #else
    return true
    #endif
  }

  /// Whether this process runs in the App Sandbox.
  ///
  /// Two Foundation-only signs, either of which is enough. The system sets `APP_SANDBOX_CONTAINER_ID`
  /// in the environment of every sandboxed app process. And a sandboxed process's home directory is
  /// redirected into its container, `~/Library/Containers/<id>/Data`, which also covers a process
  /// whose environment was cleared. The home directory is the sign that matters most here, because
  /// what decides the move is exactly whether `~/Library` (and so 0.2.0's Preferences plist and
  /// Application Support folder) resolved inside a private container. The alternatives were worse:
  /// reading the `com.apple.security.app-sandbox` entitlement needs the Security framework (the core
  /// is Foundation only) and says what the signature asks for rather than where the files went, and
  /// `sandbox_check` is not public API.
  static func isSandboxed(environment: [String: String], homeDirectory: String) -> Bool {
    if let id = environment["APP_SANDBOX_CONTAINER_ID"], !id.isEmpty { return true }
    return homeDirectory.contains("/Library/Containers/")
  }

  // MARK: The move from 0.2.0

  /// Runs the move once per process, before the first default location is handed out. Injected
  /// stores and suites (the test seams) never reach it.
  static func prepare() { _ = preparedOnce }

  private static let preparedOnce: Void = {
    migrate(
      legacyRoot: legacyRoot(base: applicationSupport),
      newRoot: rootDirectory(base: applicationSupport, host: hostIdentifier),
      legacyDefaultsName: legacyDefaultsSuite,
      defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard,
      legacyIsPrivate: legacyLocationIsPrivate
    )
  }()

  /// What `migrate` did, for the tests.
  struct MigrationOutcome: Equatable {
    var movedDefaults: [String] = []
    var movedFolders: [String] = []
  }

  /// Carries 0.2.0's entries into this app's place when they were private to it, and removes them
  /// afterwards; does nothing at all when they were shared. Safe to run at every launch: once the old
  /// entries are gone there is nothing left to move, so it needs no flag of its own. Anything that
  /// fails to move stays where it was and is tried again at the next launch, never deleted.
  @discardableResult
  static func migrate(
    legacyRoot: URL,
    newRoot: URL,
    legacyDefaultsName: String,
    defaults target: UserDefaults,
    legacyIsPrivate: Bool,
    domains: UserDefaults = .standard
  ) -> MigrationOutcome {
    var outcome = MigrationOutcome()
    // Shared with other apps: nothing there is this app's, and those apps may still be using it.
    guard legacyIsPrivate else { return outcome }

    // The suite: every key the new suite does not already have (the install id above all, and the
    // key's cached settings and the error prompt's memory with it), then the old domain goes.
    if let old = domains.persistentDomain(forName: legacyDefaultsName), !old.isEmpty {
      for (key, value) in old.sorted(by: { $0.key < $1.key }) where target.object(forKey: key) == nil {
        target.set(value, forKey: key)
        outcome.movedDefaults.append(key)
      }
      domains.removePersistentDomain(forName: legacyDefaultsName)
    }

    // The folders: the session (so a crash just before the update is still offered) and the kept
    // reports. A folder the new place already has is newer, and wins; kept reports are merged.
    let fm = FileManager.default
    for name in legacyFolders {
      let old = legacyRoot.appendingPathComponent(name, isDirectory: true)
      guard old != newRoot, fm.fileExists(atPath: old.path) else { continue }
      let new = newRoot.appendingPathComponent(name, isDirectory: true)
      do {
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: new.path) {
          try fm.moveItem(at: old, to: new)
        } else if name == "pending" {
          for file in try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            let destination = new.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: file, to: destination) }
          }
          try fm.removeItem(at: old)
        } else {
          try fm.removeItem(at: old)
        }
        outcome.movedFolders.append(name)
      } catch {
        continue
      }
    }
    return outcome
  }
}
