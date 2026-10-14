import XCTest
@testable import OverblastFeedbackCore

final class RedactorTests: XCTestCase {
  func testBearerTokens() {
    XCTAssertEqual(Redactor.redact("Authorization: Bearer abc.def-ghi_jkl123"), "Authorization: Bearer [redacted]")
    XCTAssertEqual(Redactor.redact("bearer QWERTYUIOPASDF=="), "bearer [redacted]")
  }

  func testProviderAndOverblastKeys() {
    XCTAssertEqual(Redactor.redact("key sk-proj-abcdefghijklmnop1234 used"), "key [redacted] used")
    XCTAssertEqual(Redactor.redact("sk-or-v1-0123456789abcdef0123"), "[redacted]")
    XCTAssertEqual(Redactor.redact("using ob_live_9f8e7d6c5b4a now"), "using [redacted] now")
    XCTAssertEqual(Redactor.redact("obfk_ABCDEFGHIJKLMNOPQRSTUVWX"), "[redacted]")
    // A word that merely starts with the letters is left alone.
    XCTAssertEqual(Redactor.redact("task-runner sk-short"), "task-runner sk-short")
  }

  func testJWTs() {
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    XCTAssertEqual(Redactor.redact("token \(jwt) end"), "token [redacted] end")
    XCTAssertEqual(Redactor.redact("id=\(jwt)"), "id=[redacted]")
  }

  func testLuhnValidCardNumbersOnly() {
    XCTAssertEqual(Redactor.redact("card 4242424242424242 ok"), "card [redacted] ok")
    XCTAssertEqual(Redactor.redact("card 4111 1111 1111 1111"), "card [redacted]")
    XCTAssertEqual(Redactor.redact("amex 3782-822463-10005"), "amex [redacted]")
    // Thirteen digits that fail Luhn: a millisecond timestamp survives.
    XCTAssertEqual(Redactor.redact("t=1760440000123"), "t=1760440000123")
    XCTAssertEqual(Redactor.redact("order 1234567890123"), "order 1234567890123")
    // Twelve digits are too short to be a card, Luhn or not.
    XCTAssertEqual(Redactor.redact("424242424242"), "424242424242")
    // Twenty digits are too long.
    XCTAssertEqual(Redactor.redact("42424242424242424242"), "42424242424242424242")
  }

  func testPasswordAndTokenPairs() {
    XCTAssertEqual(Redactor.redact("login password=hunter2 user=ana"), "login password=[redacted] user=ana")
    XCTAssertEqual(Redactor.redact("?token=abc123&page=2"), "?token=[redacted]&page=2")
    XCTAssertEqual(Redactor.redact(#"{"password":"hunter2","user":"ana"}"#), #"{"password":[redacted],"user":"ana"}"#)
    XCTAssertEqual(Redactor.redact("access_token: xyz789"), "access_token: [redacted]")
    XCTAssertEqual(Redactor.redact("API_KEY=foo"), "API_KEY=[redacted]")
  }

  func testOrdinaryLinesAreUntouched() {
    let line = "Loaded 12 items in 340 ms from /v1/cart (status 200)"
    XCTAssertEqual(Redactor.redact(line), line)
    XCTAssertEqual(Redactor.redact(""), "")
  }

  func testLuhn() {
    XCTAssertTrue(Redactor.luhnValid("4242424242424242"))
    XCTAssertTrue(Redactor.luhnValid("6011111111111117"))
    XCTAssertFalse(Redactor.luhnValid("4242424242424241"))
    XCTAssertFalse(Redactor.luhnValid(""))
  }
}
