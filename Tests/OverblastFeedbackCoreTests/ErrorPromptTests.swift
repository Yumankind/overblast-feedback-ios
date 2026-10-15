import XCTest
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

/// Contract §2.1 (the config door) and §3.6 (the error prompt's rules), with the clock passed in.
final class ErrorPromptTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_440_000)
  private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
  private let calm = ErrorPromptGate.Conditions()
  private func gate(on: [FeedbackRemoteConfig.ErrorPrompt.Kind] = [.exception], hours: Double = 24, persisted: ErrorPromptGate.Persisted = .init()) -> ErrorPromptGate {
    ErrorPromptGate(startedAt: t0, settings: .init(enabled: true, on: on, minHoursBetween: hours), persisted: persisted)
  }

  // MARK: When

  func testNotInTheFirstTenSecondsAndAFullSecondAfterTheError() {
    var g = gate()
    XCTAssertEqual(g.decide(at: at(1), calm), .idle)
    XCTAssertTrue(g.noteError(.exception, at: at(2)))
    XCTAssertEqual(g.decide(at: at(2.5), calm), .wait(until: at(10)))
    XCTAssertEqual(g.decide(at: at(10), calm), .show)

    var later = gate()
    later.noteError(.exception, at: at(20))
    XCTAssertEqual(later.decide(at: at(20.2), calm), .wait(until: at(21)))
    XCTAssertEqual(later.decide(at: at(21), calm), .show)
  }

  func testTwoErrorsASecondApartAreOnePrompt() {
    var g = gate()
    XCTAssertTrue(g.noteError(.exception, at: at(20)))
    XCTAssertFalse(g.noteError(.exception, at: at(20.6)))
    XCTAssertEqual(g.pendingSince, at(20))
    XCTAssertEqual(g.decide(at: at(21), calm), .show)
    g.shown(at: at(21))
    XCTAssertEqual(g.decide(at: at(22), calm), .idle)
  }

  func testItWaitsForTheKeyboardAndGivesUpAfterThirtySeconds() {
    var g = gate()
    g.noteError(.exception, at: at(20))
    let typing = ErrorPromptGate.Conditions(isKeyboardUp: true)
    XCTAssertEqual(g.decide(at: at(21), typing), .wait(until: at(21.5)))
    XCTAssertEqual(g.decide(at: at(49), typing), .wait(until: at(49.5)))
    XCTAssertEqual(g.decide(at: at(50.1), typing), .idle)
    XCTAssertNil(g.pendingSince)
    XCTAssertEqual(g.decide(at: at(51), calm), .idle, "given up: nothing left to show")
  }

  func testOnlyTypingHoldsItBackNotFocus() {
    var g = gate()
    g.noteError(.exception, at: at(20))
    // Text changed two seconds ago: still typing.
    XCTAssertEqual(g.decide(at: at(21), .init(lastTextEditAt: at(19))), .wait(until: at(21.5)))
    // Five seconds after the last change the person has stopped, even if the field keeps focus
    // (focus alone is not in the conditions at all).
    XCTAssertEqual(g.decide(at: at(24.1), .init(lastTextEditAt: at(19))), .show)
    XCTAssertTrue(ErrorPromptGate.Conditions(lastTextEditAt: at(0)).isTyping(at: at(4.9)))
    XCTAssertFalse(ErrorPromptGate.Conditions(lastTextEditAt: at(0)).isTyping(at: at(5)))
    XCTAssertFalse(ErrorPromptGate.Conditions().isTyping(at: at(5)))
  }

  func testTypingThatNeverStopsGivesUpAfterThirtySeconds() {
    var g = gate()
    g.noteError(.exception, at: at(20))
    for second in stride(from: 21.0, through: 50.0, by: 1) {
      XCTAssertNotEqual(g.decide(at: at(second), .init(lastTextEditAt: at(second - 1))), .show)
    }
    XCTAssertEqual(g.decide(at: at(50.5), .init(lastTextEditAt: at(50))), .idle)
  }

  func testNotOverTheSheetAnAlertOrTheCrashOfferNorInTheBackground() {
    var g = gate()
    g.noteError(.exception, at: at(20))
    XCTAssertEqual(g.decide(at: at(21), .init(isBlockingUIShowing: true)), .wait(until: at(21.5)))
    XCTAssertEqual(g.decide(at: at(22), .init(isForeground: false)), .wait(until: at(22.5)))
    XCTAssertEqual(g.decide(at: at(23), calm), .show)
  }

  // MARK: How often

  func testOncePerSession() {
    var g = gate(hours: 0)
    g.noteError(.exception, at: at(20))
    g.shown(at: at(21))
    XCTAssertFalse(g.noteError(.exception, at: at(100)))
  }

  func testOncePerMinHoursOnTheDevice() {
    let previous = ErrorPromptGate.Persisted(lastShownAt: at(-3600))
    var g = gate(hours: 2, persisted: previous)
    XCTAssertFalse(g.noteError(.exception, at: at(20)), "an hour ago, and the key says two")
    var next = gate(hours: 2, persisted: ErrorPromptGate.Persisted(lastShownAt: at(-7300)))
    XCTAssertTrue(next.noteError(.exception, at: at(20)))
  }

  func testTwoDismissalsWithoutReportingMeanAWeekOfQuiet() {
    var g = gate(hours: 0)
    g.dismissed(at: at(30))
    XCTAssertNil(g.persisted.quietUntil)
    g.dismissed(at: at(40))
    XCTAssertEqual(g.persisted.quietUntil, at(40 + 7 * 24 * 3600))
    var nextLaunch = ErrorPromptGate(startedAt: at(100), settings: g.settings, persisted: g.persisted)
    XCTAssertFalse(nextLaunch.noteError(.exception, at: at(3 * 24 * 3600)))
    XCTAssertTrue(nextLaunch.noteError(.exception, at: at(8 * 24 * 3600)))
  }

  func testReportingResetsTheDismissals() {
    var g = gate(hours: 0)
    g.dismissed(at: at(30))
    g.reported()
    g.dismissed(at: at(40))
    XCTAssertNil(g.persisted.quietUntil)
    XCTAssertEqual(g.persisted.dismissalsWithoutReport, 1)
  }

  func testOnlyTheKindsTheKeyAsksFor() {
    var g = gate(on: [.serverError])
    XCTAssertFalse(g.noteError(.exception, at: at(20)))
    XCTAssertFalse(g.noteError(.network, at: at(20)))
    XCTAssertTrue(g.noteError(.serverError, at: at(20)))
    var off = ErrorPromptGate(startedAt: t0, settings: .init(enabled: false, on: [.exception]))
    XCTAssertFalse(off.noteError(.exception, at: at(20)))
  }

  // MARK: The center

  func testRequestsCountOnlyFromTheAppsOwnHostsAndOnly5xxOrNoAnswer() throws {
    let center = ErrorPromptCenter()
    let defaults = scratchDefaults("obf-prompt")
    let fired = Counter()
    center.activate(startedAt: t0, settings: .init(enabled: true, on: [.serverError, .network], minHoursBetween: 24), appHosts: ["API.example.com"], defaults: defaults) { fired.bump() }
    center.noteRequest(host: "api.example.com", status: 404, at: at(20))
    center.noteRequest(host: "cdn.other.com", status: 503, at: at(20))
    XCTAssertEqual(fired.value, 0)
    center.noteRequest(host: "api.example.com", status: 502, at: at(20))
    XCTAssertEqual(fired.value, 1)
    center.noteRequest(host: "api.example.com", status: 0, at: at(20.5))
    XCTAssertEqual(fired.value, 1, "merged into the one waiting")
    XCTAssertEqual(center.decide(at: at(21), calm), .show)
    center.shown(at: at(21))
    center.dismissed(at: at(25))
    // What lasts is written to the defaults suite.
    let data = try XCTUnwrap(defaults.data(forKey: ErrorPromptCenter.persistedKey))
    let persisted = try JSONDecoder().decode(ErrorPromptGate.Persisted.self, from: data)
    XCTAssertEqual(persisted.lastShownAt, at(21))
    XCTAssertEqual(persisted.dismissalsWithoutReport, 1)
  }

  // MARK: The config door

  func testTheConfigDecodesTolerantlyAndDefaultsToOff() throws {
    let json = #"{"verification":"flag","errorPrompt":{"enabled":true,"on":["exception","future_kind","network"],"minHoursBetween":6},"screenshots":false}"#
    let c = try JSONDecoder().decode(FeedbackRemoteConfig.self, from: Data(json.utf8))
    XCTAssertEqual(c.verification, .flag)
    XCTAssertEqual(c.errorPrompt, .init(enabled: true, on: [.exception, .network], minHoursBetween: 6))
    XCTAssertFalse(c.screenshots)
    let empty = try JSONDecoder().decode(FeedbackRemoteConfig.self, from: Data("{}".utf8))
    XCTAssertEqual(empty, .defaults)
    XCTAssertEqual(FeedbackRemoteConfig.defaults.verification, .off)
    XCTAssertFalse(FeedbackRemoteConfig.defaults.errorPrompt.enabled)
    XCTAssertTrue(FeedbackRemoteConfig.defaults.screenshots)
  }

  // MARK: Categories (contract §2)

  func testCategoriesDecodeInTheKeysOrderAndDefaultToAllFour() throws {
    func decode(_ json: String) throws -> [FeedbackCategory] {
      try JSONDecoder().decode(FeedbackRemoteConfig.self, from: Data(json.utf8)).categories
    }
    XCTAssertEqual(try decode("{}"), [.bug, .idea, .question, .other])
    XCTAssertEqual(try decode(#"{"categories":["bug"]}"#), [.bug])
    XCTAssertEqual(try decode(#"{"categories":["question","idea","question"]}"#), [.question, .idea])
    XCTAssertEqual(try decode(#"{"categories":["praise","idea"]}"#), [.idea], "a kind this version does not know is left out")
    XCTAssertEqual(try decode(#"{"categories":[]}"#), FeedbackCategory.allCases)
    XCTAssertEqual(try decode(#"{"categories":["praise"]}"#), FeedbackCategory.allCases)
  }

  func testTheSheetsCategoryAndTheProblemOnlyKey() {
    let bugsOnly = FeedbackEffectiveConfig.combine(FeedbackRemoteConfig(categories: [.bug]), FeedbackOptions())
    XCTAssertTrue(bugsOnly.isProblemReportsOnly)
    XCTAssertEqual(bugsOnly.category(for: nil), .bug)
    XCTAssertEqual(bugsOnly.category(for: .idea), .bug)
    let some = FeedbackEffectiveConfig.combine(FeedbackRemoteConfig(categories: [.idea, .question]), FeedbackOptions())
    XCTAssertFalse(some.isProblemReportsOnly)
    XCTAssertEqual(some.category(for: nil), .idea, "the first is the default")
    XCTAssertEqual(some.category(for: .question), .question)
    XCTAssertEqual(some.category(for: .bug), .idea)
    let all = FeedbackEffectiveConfig.combine(.defaults, FeedbackOptions())
    XCTAssertEqual(all.categories, FeedbackCategory.allCases)
    XCTAssertEqual(all.category(for: nil), .bug)
    XCTAssertNil(all.refusal(for: .other))
    XCTAssertEqual(bugsOnly.refusal(for: .idea), .refused(status: 403, code: "category_not_accepted", message: "This app only takes problem reports.", field: "category"))
    XCTAssertNil(bugsOnly.refusal(for: .bug))
    XCTAssertEqual(some.refusal(for: .bug)?.message, "This app doesn't take that kind of report.")
  }

  func testAReportInACategoryTheKeyDoesNotTakeIsNotSent() async throws {
    let defaults = scratchDefaults("obf-categories")
    let cached = RemoteConfigStore.Cached(config: FeedbackRemoteConfig(categories: [.bug]), etag: nil, fetchedAt: Date())
    defaults.set(try JSONEncoder().encode(cached), forKey: RemoteConfigStore.cacheKey)
    let pending = FileManager.default.temporaryDirectory.appendingPathComponent("obf-cat-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pending) }
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000", endpoint: URL(string: "https://feedback.test/v1/feedback")!, reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: StubProtocol.session(), store: PendingStore(directory: pending), defaults: defaults
    )
    XCTAssertTrue(OverblastFeedback.effectiveConfig.isProblemReportsOnly)
    StubProtocol.reset([])
    do {
      try await OverblastFeedback.report(message: "a feature idea", category: .idea, logs: [])
      XCTFail("expected the local refusal")
    } catch let error as FeedbackError {
      XCTAssertEqual(error, .refused(status: 403, code: "category_not_accepted", message: "This app only takes problem reports.", field: "category"))
      XCTAssertFalse(error.keepsForLater)
    }
    XCTAssertTrue(StubProtocol.seen.isEmpty, "nothing was sent")
    XCTAssertEqual(OverblastFeedback.pendingCount, 0, "and nothing kept")
    // Put the engine back to the defaults for the other tests in this process.
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000", endpoint: URL(string: "https://feedback.test/v1/feedback")!, reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: StubProtocol.session(), store: PendingStore(directory: pending), defaults: scratchDefaults("obf-categories")
    )
  }

  func testLocalOptionsCanOnlyTurnThingsOff() {
    let on = FeedbackRemoteConfig(verification: .require, errorPrompt: .init(enabled: true), screenshots: true)
    let all = FeedbackEffectiveConfig.combine(on, FeedbackOptions())
    XCTAssertTrue(all.deviceRegistration)
    XCTAssertTrue(all.screenshots)
    XCTAssertNotNil(all.errorPrompt)
    let none = FeedbackEffectiveConfig.combine(on, FeedbackOptions(device: false, screenshots: false, errorPrompt: false))
    XCTAssertFalse(none.deviceRegistration)
    XCTAssertFalse(none.screenshots)
    XCTAssertNil(none.errorPrompt)
    // The defaults (no answer yet): nothing on but screenshots, whatever the options say.
    let before = FeedbackEffectiveConfig.combine(.defaults, FeedbackOptions(device: true, errorPrompt: true))
    XCTAssertFalse(before.deviceRegistration)
    XCTAssertNil(before.errorPrompt)
    XCTAssertTrue(before.screenshots)
  }

  func testTheConfigIsKeptReadEveryFiveMinutesAndUsedOffline() async throws {
    let defaults = scratchDefaults("obf-config")
    let client = FeedbackClient(endpoint: URL(string: "https://feedback.test/v1/feedback")!, key: "obfk_TESTKEY00000000000000000", session: StubProtocol.session())
    let store = RemoteConfigStore(defaults: defaults)
    XCTAssertEqual(store.current, .defaults)

    StubProtocol.reset([.http(200, #"{"verification":"off","errorPrompt":{"enabled":true,"on":["exception"],"minHoursBetween":24},"screenshots":false}"#, ["ETag": "\"v1\""])])
    await store.refreshIfStale(client: client, now: at(0))
    XCTAssertFalse(store.current.screenshots)
    let first = try XCTUnwrap(StubProtocol.seen.first?.request)
    XCTAssertEqual(first.url?.absoluteString, "https://feedback.test/v1/feedback/config")
    XCTAssertEqual(first.httpMethod, "GET")
    XCTAssertEqual(first.value(forHTTPHeaderField: FeedbackClient.keyHeader), "obfk_TESTKEY00000000000000000")

    // Within five minutes: no request at all.
    StubProtocol.reset([])
    await store.refreshIfStale(client: client, now: at(120))
    XCTAssertTrue(StubProtocol.seen.isEmpty)

    // After five minutes, with the ETag; a 304 keeps the answer.
    StubProtocol.reset([.http(304, "", [:])])
    await store.refreshIfStale(client: client, now: at(301))
    XCTAssertEqual(StubProtocol.seen.first?.request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
    XCTAssertFalse(store.current.screenshots)

    // Offline: the kept answer stands, and a new launch reads it from the suite.
    StubProtocol.reset([.failure(.notConnectedToInternet)])
    await store.refreshIfStale(client: client, now: at(1_000))
    XCTAssertFalse(store.current.screenshots)
    XCTAssertTrue(RemoteConfigStore(defaults: defaults).current.errorPrompt.enabled)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return n }
  func bump() { lock.lock(); n += 1; lock.unlock() }
}
