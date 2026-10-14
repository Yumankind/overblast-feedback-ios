import Foundation

/// Everything a report can be refused for, said once each.
///
/// Every refusal from the worker carries a sentence in `error` that is written to be shown to the
/// reporter as it is (contract §3.3), so `message` is that sentence verbatim wherever the worker sent
/// one, and a plain English fallback only where it did not.
public enum FeedbackError: Error, Sendable, Equatable {
  /// `OverblastFeedback.start` (or `configure`) has not been called.
  case notStarted
  /// Caught before sending: an empty message, an address that is not one, a screenshot too large.
  /// `field` is the contract's dotted name for it.
  case invalidReport(field: String, message: String)
  /// The worker refused: `invalid_field` (400), `unknown_key` (401), `key_disabled` and
  /// `origin_not_allowed` (403), `too_large` (413), `misconfigured` (500), or a code this version
  /// does not know. Sending the same report again would be refused the same way.
  case refused(status: Int, code: String, message: String, field: String?)
  /// `507 storage_full`. The task WAS filed, without the screenshot and the report file. Do not send
  /// it again.
  case storageFull(message: String)
  /// `429 rate_limited`. The report was kept on the device and is sent on the next launch or by
  /// `retryPending()`. `retryAfter` is in seconds.
  case rateLimited(retryAfter: Int?, message: String)
  /// No connection, or the service did not answer (a timeout, a 502/503/504 from the edge). The
  /// report was kept on the device, as for `rateLimited`.
  case offline(message: String)

  /// The sentence to show the reporter.
  public var message: String {
    switch self {
    case .notStarted:
      return "Feedback is not set up in this app."
    case let .invalidReport(_, message),
         let .refused(_, _, message, _),
         let .storageFull(message),
         let .rateLimited(_, message),
         let .offline(message):
      return message
    }
  }

  /// True when the report is worth keeping and sending later: a rate limit or no connection. Every
  /// other refusal would be repeated word for word.
  public var keepsForLater: Bool {
    switch self {
    case .rateLimited, .offline: return true
    default: return false
    }
  }

  /// True when the worker filed the task despite the error.
  public var wasFiled: Bool {
    if case .storageFull = self { return true }
    return false
  }

  /// The worker's `code`, where it sent one.
  public var code: String? {
    switch self {
    case let .refused(_, code, _, _): return code
    case .storageFull: return "storage_full"
    case .rateLimited: return "rate_limited"
    default: return nil
    }
  }
}

extension FeedbackError: LocalizedError {
  public var errorDescription: String? { message }
}
