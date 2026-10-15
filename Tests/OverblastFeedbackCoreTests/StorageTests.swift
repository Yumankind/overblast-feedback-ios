import XCTest
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

/// Where the library keeps things: one place per app, and the move from 0.2.0's shared names. Every
/// test works under its own temporary folder and its own in-memory defaults (`MemoryDefaults`), never
/// the real ones: the migration's suites and the domains it reads by name all live in `store`.
final class StorageTests: XCTestCase {
  private var base: URL!
  private var store = MemoryDefaults.Store()
  private var domains: UserDefaults { MemoryDefaults(store: store, name: nil)! }

  override func setUp() {
    super.setUp()
    base = FileManager.default.temporaryDirectory.appendingPathComponent("obf-storage-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: base)
    store = MemoryDefaults.Store()
    super.tearDown()
  }

  private func suiteName(_ label: String) -> String {
    "obf-storage-\(label)-\(UUID().uuidString)"
  }

  private func suite(_ name: String) throws -> UserDefaults {
    try XCTUnwrap(MemoryDefaults(store: store, name: name))
  }

  private func draft(_ message: String) -> FeedbackPayload {
    FeedbackPayload(message: message, context: FeedbackContext(deviceId: "dev1"))
  }

  /// What 0.2.0 left behind: an install id in the shared suite, a session that never closed, and a
  /// kept report, all under the shared names.
  private func leaveLegacyState(suite legacyName: String, id: String) throws -> URL {
    try suite(legacyName).set(id, forKey: DeviceInfo.deviceIdKey)
    let legacyRoot = FeedbackStorage.legacyRoot(base: base)
    let oldSession = SessionStore(directory: legacyRoot.appendingPathComponent("session"))
    oldSession.begin(now: Date(timeIntervalSince1970: 100))
    oldSession.appendLogs([FeedbackLogBuffer.Stored(seq: 1, entry: FeedbackLogEntry(t: 100_000, level: .info, msg: "before the update", src: "app"))], now: Date(timeIntervalSince1970: 120))
    // ...and the app ended without closing it.
    try PendingStore(directory: legacyRoot.appendingPathComponent("pending")).save(draft("kept by 0.2.0"))
    return legacyRoot
  }

  // MARK: Names

  func testTheHostIsTheBundleIdElseTheExecutableAndAlwaysASafeName() {
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: "app.deskslap.mac", processName: "Deskslap"), "app.deskslap.mac")
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: nil, processName: "mytool"), "mytool")
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: "  ", processName: "my tool/v2"), "my_tool_v2")
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: nil, processName: ""), "unknown-host")
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: nil, processName: ".."), "unknown-host")
    // Never the name of one of 0.2.0's folders, which sit beside the hosts' own.
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: nil, processName: "session"), "host-session")
    XCTAssertEqual(FeedbackStorage.hostIdentifier(bundleIdentifier: nil, processName: "pending"), "host-pending")
    XCTAssertEqual(FeedbackStorage.defaultsSuite(host: "app.deskslap.mac"), "network.deployd.overblast-feedback.app.deskslap.mac")
    XCTAssertTrue(DeviceInfo.defaultsSuite.hasPrefix(FeedbackStorage.legacyDefaultsSuite + "."))
    XCTAssertNotEqual(DeviceInfo.defaultsSuite, FeedbackStorage.legacyDefaultsSuite)
  }

  func testTwoAppsGetSeparateStores() throws {
    let a = FeedbackStorage.rootDirectory(base: base, host: "com.example.a")
    let b = FeedbackStorage.rootDirectory(base: base, host: "com.example.b")
    XCTAssertNotEqual(a, b)
    XCTAssertNotEqual(FeedbackStorage.defaultsSuite(host: "com.example.a"), FeedbackStorage.defaultsSuite(host: "com.example.b"))

    // App A ends without closing its session and keeps a report: app B sees neither.
    SessionStore(directory: a.appendingPathComponent("session")).begin(now: Date(timeIntervalSince1970: 100))
    try PendingStore(directory: a.appendingPathComponent("pending")).save(draft("A's report"))
    XCTAssertNil(SessionStore(directory: b.appendingPathComponent("session")).begin(), "no false crash offer from another app's session")
    XCTAssertTrue(PendingStore(directory: b.appendingPathComponent("pending")).all().isEmpty)
    // A still has both.
    XCTAssertNotNil(SessionStore(directory: a.appendingPathComponent("session")).begin())
    XCTAssertEqual(PendingStore(directory: a.appendingPathComponent("pending")).all().map(\.payload.message), ["A's report"])

    // And their install ids are their own.
    let idA = DeviceInfo.deviceId(defaults: try suite(suiteName("a")))
    let idB = DeviceInfo.deviceId(defaults: try suite(suiteName("b")))
    XCTAssertNotEqual(idA, idB)
  }

  func testTheDefaultLocationsAreUnderThisAppsOwnFolder() {
    let root = FeedbackStorage.rootDirectory
    XCTAssertEqual(root.lastPathComponent, FeedbackStorage.hostIdentifier)
    XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "OverblastFeedback")
    XCTAssertEqual(SessionStore.defaultDirectory(), root.appendingPathComponent("session", isDirectory: true))
    XCTAssertEqual(PendingStore.defaultDirectory(), root.appendingPathComponent("pending", isDirectory: true))
  }

  // MARK: Sandboxing

  func testSandboxingIsReadFromTheEnvironmentOrTheContainerHome() {
    XCTAssertTrue(FeedbackStorage.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "app.deskslap.mac"], homeDirectory: "/Users/ana"))
    XCTAssertTrue(FeedbackStorage.isSandboxed(environment: [:], homeDirectory: "/Users/ana/Library/Containers/app.deskslap.mac/Data"))
    XCTAssertFalse(FeedbackStorage.isSandboxed(environment: [:], homeDirectory: "/Users/ana"))
    XCTAssertFalse(FeedbackStorage.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": ""], homeDirectory: "/Users/ana"))
  }

  // MARK: The move from 0.2.0

  func testAPrivateOldLocationIsCarriedOverOnceAndThenRemoved() throws {
    let legacyName = suiteName("legacy")
    let targetName = suiteName("target")
    let legacyId = String(repeating: "ab", count: 16)
    let legacyRoot = try leaveLegacyState(suite: legacyName, id: legacyId)
    let newRoot = FeedbackStorage.rootDirectory(base: base, host: "com.example.app")
    let target = try suite(targetName)

    let outcome = FeedbackStorage.migrate(legacyRoot: legacyRoot, newRoot: newRoot, legacyDefaultsName: legacyName, defaults: target, legacyIsPrivate: true, domains: domains)
    XCTAssertEqual(outcome.movedDefaults, [DeviceInfo.deviceIdKey])
    XCTAssertEqual(outcome.movedFolders, ["session", "pending"])

    // The install keeps its device id...
    XCTAssertEqual(DeviceInfo.deviceId(defaults: target), legacyId)
    // ...the crash just before the update is still offered, with its logs...
    let previous = try XCTUnwrap(SessionStore(directory: newRoot.appendingPathComponent("session")).begin())
    XCTAssertEqual(previous.logs.map(\.msg), ["before the update"])
    // ...and the kept report is still kept.
    XCTAssertEqual(PendingStore(directory: newRoot.appendingPathComponent("pending")).all().map(\.payload.message), ["kept by 0.2.0"])

    // The old entries are gone, so a second launch has nothing to move.
    // (A removed domain can read back as empty rather than nil within the same process.)
    XCTAssertTrue((domains.persistentDomain(forName: legacyName) ?? [:]).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("session").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("pending").path))
    let again = FeedbackStorage.migrate(legacyRoot: legacyRoot, newRoot: newRoot, legacyDefaultsName: legacyName, defaults: target, legacyIsPrivate: true, domains: domains)
    XCTAssertEqual(again, FeedbackStorage.MigrationOutcome())
    XCTAssertEqual(DeviceInfo.deviceId(defaults: target), legacyId)
  }

  func testWhatTheNewPlaceAlreadyHasWinsAndKeptReportsAreMerged() throws {
    let legacyName = suiteName("legacy")
    let target = try suite(suiteName("target"))
    let legacyRoot = try leaveLegacyState(suite: legacyName, id: String(repeating: "ab", count: 16))
    let newRoot = FeedbackStorage.rootDirectory(base: base, host: "com.example.app")
    let newId = String(repeating: "cd", count: 16)
    target.set(newId, forKey: DeviceInfo.deviceIdKey)
    try PendingStore(directory: newRoot.appendingPathComponent("pending")).save(draft("kept by 0.2.1"), now: Date().addingTimeInterval(1))

    FeedbackStorage.migrate(legacyRoot: legacyRoot, newRoot: newRoot, legacyDefaultsName: legacyName, defaults: target, legacyIsPrivate: true, domains: domains)
    XCTAssertEqual(DeviceInfo.deviceId(defaults: target), newId)
    XCTAssertEqual(PendingStore(directory: newRoot.appendingPathComponent("pending")).all().map(\.payload.message), ["kept by 0.2.0", "kept by 0.2.1"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("pending").path))
  }

  func testASharedOldLocationIsNeverAdoptedAndLeftAlone() throws {
    let legacyName = suiteName("legacy")
    let target = try suite(suiteName("target"))
    let legacyId = String(repeating: "ab", count: 16)
    let legacyRoot = try leaveLegacyState(suite: legacyName, id: legacyId)
    let newRoot = FeedbackStorage.rootDirectory(base: base, host: "app.deskslap.mac")

    let outcome = FeedbackStorage.migrate(legacyRoot: legacyRoot, newRoot: newRoot, legacyDefaultsName: legacyName, defaults: target, legacyIsPrivate: false, domains: domains)
    XCTAssertEqual(outcome, FeedbackStorage.MigrationOutcome())

    // A fresh start: no false "The app closed unexpectedly", no other app's kept reports, an id of
    // its own.
    XCTAssertNil(SessionStore(directory: newRoot.appendingPathComponent("session")).begin())
    XCTAssertTrue(PendingStore(directory: newRoot.appendingPathComponent("pending")).all().isEmpty)
    XCTAssertNotEqual(DeviceInfo.deviceId(defaults: target), legacyId)

    // The shared entries are untouched, for the apps still on 0.2.0.
    XCTAssertEqual(domains.persistentDomain(forName: legacyName)?[DeviceInfo.deviceIdKey] as? String, legacyId)
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("session/session.json").path))
    XCTAssertEqual(PendingStore(directory: legacyRoot.appendingPathComponent("pending")).all().map(\.payload.message), ["kept by 0.2.0"])
  }

  // MARK: Results

  func testAnythingReportThrowsBecomesAFeedbackError() {
    let refused = FeedbackError.refused(status: 401, code: "unknown_key", message: "No.", field: nil)
    XCTAssertEqual(OverblastFeedback.feedbackError(from: refused), refused)
    struct Odd: Error {}
    if case .invalidReport(let field, _) = OverblastFeedback.feedbackError(from: Odd()) {
      XCTAssertEqual(field, "body")
    } else {
      XCTFail("expected invalidReport")
    }
  }

  @MainActor
  func testTheOpenersHandlerIsCalledBeforeTheAppWideOne() {
    var calls: [String] = []
    OverblastFeedback.onReportResult = { result in
      if case let .success(receipt) = result { calls.append("app:\(receipt.id)") }
    }
    defer { OverblastFeedback.onReportResult = nil }
    OverblastFeedback.deliverReportResult(.success(FeedbackReceipt(id: "fbr_1", taskId: "t_1", conversationId: nil)), to: { result in
      if case let .success(receipt) = result { calls.append("opener:\(receipt.id)") }
    })
    OverblastFeedback.deliverReportResult(.failure(.offline(message: "x")), to: nil)
    XCTAssertEqual(calls, ["opener:fbr_1", "app:fbr_1"])
  }
}
