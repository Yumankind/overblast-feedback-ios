import Foundation

/// Replaces values that look like credentials with `[redacted]` before a log line or a URL leaves the
/// device (contract §6).
///
/// It is applied to log messages and network URLs, never to the reporter's own message: what a person
/// typed into the sheet they meant to send. The patterns err on the side of cutting, because a log
/// line with a hole in it is still useful and a leaked token is not recoverable.
public enum Redactor {
  public static let mask = "[redacted]"

  private struct Rule: @unchecked Sendable {
    // NSRegularExpression is immutable and documented as safe to share between threads.
    let regex: NSRegularExpression
    let template: String
  }

  private static let rules: [Rule] = {
    func rule(_ pattern: String, _ template: String) -> Rule {
      // The patterns are constants; a typo is a programming error the tests catch.
      Rule(regex: try! NSRegularExpression(pattern: pattern, options: []), template: template)
    }
    return [
      // Authorization: Bearer <token>
      rule(#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 \(mask)"),
      // A JWT: three base64url segments, the first two starting with the encoding of `{"`.
      rule(#"\beyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#, mask),
      // sk-... (OpenAI, OpenRouter, Anthropic and most of their imitators), Overblast live keys and
      // feedback keys.
      rule(#"\bsk-[A-Za-z0-9_-]{12,}"#, mask),
      rule(#"\bob_live_[A-Za-z0-9_-]{8,}"#, mask),
      rule(#"\bobfk_[A-Za-z0-9]{8,}"#, mask),
      // password=..., token: ..., "api_key": "...", in query strings, form bodies, JSON and prose.
      rule(
        #"(?i)(["']?\b(?:password|passwd|pwd|secret|client_secret|token|access_token|refresh_token|id_token|api_?key|auth)\b["']?\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s&,;"'}]+)"#,
        "$1\(mask)"
      ),
    ]
  }()

  /// Runs of 13 to 19 digits, optionally grouped by single spaces or dashes. Checked by Luhn before
  /// they are cut, so an order number or a timestamp survives.
  private static let cardCandidate = Rule(
    regex: try! NSRegularExpression(pattern: #"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#, options: []),
    template: ""
  )

  public static func redact(_ input: String) -> String {
    guard !input.isEmpty else { return input }
    var s = input
    for rule in rules {
      let range = NSRange(s.startIndex..., in: s)
      s = rule.regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: rule.template)
    }
    return redactCards(s)
  }

  static func redactCards(_ s: String) -> String {
    let ns = s as NSString
    let matches = cardCandidate.regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }
    let out = NSMutableString(string: s)
    // Back to front, so earlier ranges stay valid.
    for match in matches.reversed() {
      let digits = ns.substring(with: match.range).filter(\.isNumber)
      if (13...19).contains(digits.count), luhnValid(digits) {
        out.replaceCharacters(in: match.range, with: mask)
      }
    }
    return out as String
  }

  /// The Luhn check over a string of ASCII digits.
  public static func luhnValid(_ digits: String) -> Bool {
    var sum = 0
    var double = false
    for ch in digits.reversed() {
      guard let d = ch.wholeNumberValue else { return false }
      if double {
        let x = d * 2
        sum += x > 9 ? x - 9 : x
      } else {
        sum += d
      }
      double.toggle()
    }
    return !digits.isEmpty && sum % 10 == 0
  }
}
