import Foundation

/// The contract's limits (§3.1, §3.2), in one place.
///
/// Lengths are measured in UTF-16 code units, which is how the worker's JavaScript measures a
/// string. A string that fits in UTF-16 units also fits counted by code points or by characters, so
/// truncating to this measure is safe whichever way the other side counts.
public enum FeedbackLimits {
  public static let message = 4000
  public static let reporterName = 120
  public static let reporterAccountRef = 200
  public static let email = 254
  public static let url = 2000
  public static let screen = 200
  public static let title = 200
  public static let shortField = 40      // appVersion, build, os, osVersion, locale, timeZone
  public static let device = 80
  public static let userAgent = 400
  public static let deviceId = 64
  public static let extraKeys = 20
  public static let extraValue = 200

  public static let pathSteps = 12
  public static let pathStep = 80
  public static let elementType = 80
  public static let elementId = 120
  public static let elementLabel = 120

  public static let screenshotBytes = 5 * 1024 * 1024
  public static let screenshotTypes: Set<String> = ["image/png", "image/jpeg", "image/webp"]

  public static let logEntries = 500
  public static let logMessage = 4000
  public static let logSource = 40
  /// "≤ 256 KB in all". Measured as the UTF-8 size of the encoded `logs` array, and held at 256,000
  /// rather than 262,144 so that it fits whichever kilobyte the worker means.
  public static let logBytes = 256_000

  public static let networkEntries = 100
  public static let networkURL = 500
  public static let networkMethod = 16

  /// The whole body.
  public static let bodyBytes = 8 * 1024 * 1024
}

/// Cuts strings to a limit without splitting a character.
public enum FeedbackText {
  /// `s` cut to at most `max` UTF-16 units, at a character boundary, with surrounding whitespace
  /// trimmed first. An ellipsis marks a cut, inside the limit.
  public static func truncate(_ s: String, _ max: Int, ellipsis: Bool = true) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.utf16.count <= max { return trimmed }
    let mark = ellipsis && max > 1 ? "…" : ""
    let budget = max - mark.utf16.count
    var out = ""
    var used = 0
    for ch in trimmed {
      let n = String(ch).utf16.count
      if used + n > budget { break }
      out.append(ch)
      used += n
    }
    return out + mark
  }

  /// Like `truncate`, but nil and empty both become nil.
  public static func optional(_ s: String?, _ max: Int, ellipsis: Bool = true) -> String? {
    guard let s else { return nil }
    let out = truncate(s, max, ellipsis: ellipsis)
    return out.isEmpty ? nil : out
  }

  /// A plausible address: one `@`, something before it, a dot after it, no spaces. The worker is
  /// the judge; this only stops the obvious typo before it costs a round trip.
  public static func isPlausibleEmail(_ s: String) -> Bool {
    let parts = s.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
          !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
          s.utf16.count <= FeedbackLimits.email,
          s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else { return false }
    return true
  }

  /// A URL with its query string and fragment removed, for a network entry.
  public static func strippedURL(_ url: URL) -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return String(url.absoluteString.prefix { $0 != "?" && $0 != "#" })
    }
    parts.query = nil
    parts.fragment = nil
    // Credentials in the authority are as private as a query string.
    parts.user = nil
    parts.password = nil
    return parts.string ?? String(url.absoluteString.prefix { $0 != "?" && $0 != "#" })
  }

  static let deviceIdAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

  static func isValidDeviceId(_ s: String) -> Bool {
    !s.isEmpty && s.utf16.count <= FeedbackLimits.deviceId && s.unicodeScalars.allSatisfy { deviceIdAllowed.contains($0) }
  }
}

extension FeedbackPayload {
  /// This payload with every limit applied: strings cut, lists capped (newest kept), the element's
  /// rectangle clamped, logs and network URLs redacted, and empty sections left out.
  ///
  /// It throws only for what cannot be repaired by cutting: an empty message, an email address that
  /// is not one, a screenshot over 5 MB or of a type the worker does not take. Those are refusals the
  /// worker would make anyway, and making them here means the reporter can fix them before anything
  /// is sent.
  public func sanitized() throws -> FeedbackPayload {
    var out = self

    out.message = FeedbackText.truncate(message, FeedbackLimits.message)
    if out.message.isEmpty {
      throw FeedbackError.invalidReport(field: "message", message: "Please say what happened.")
    }

    if var r = reporter {
      if let email = r.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
        guard FeedbackText.isPlausibleEmail(email) else {
          throw FeedbackError.invalidReport(field: "reporter.email", message: "That email address doesn't look right.")
        }
        r.email = email
      } else {
        r.email = nil
      }
      r.name = FeedbackText.optional(r.name, FeedbackLimits.reporterName)
      // An account reference is an id; an ellipsis inside it would make a different id.
      r.accountRef = FeedbackText.optional(r.accountRef, FeedbackLimits.reporterAccountRef, ellipsis: false)
      out.reporter = r.isEmpty ? nil : r
    }

    out.context = context.sanitized()
    out.element = element.map(NativeAnchorBuilder.clamp)

    if let shot = screenshot {
      guard FeedbackLimits.screenshotTypes.contains(shot.contentType) else {
        throw FeedbackError.invalidReport(field: "screenshot.contentType", message: "The screenshot is not an image the service accepts.")
      }
      guard shot.decodedByteCount <= FeedbackLimits.screenshotBytes else {
        throw FeedbackError.invalidReport(field: "screenshot", message: "The screenshot is too large to send.")
      }
      if shot.base64.isEmpty { out.screenshot = nil }
    }

    out.logs = Self.capLogs(logs ?? [])
    out.network = Self.capNetwork(network ?? [])
    return out
  }

  /// Newest 500, each line redacted and cut, then the oldest dropped until the encoded array is
  /// within 256 KB. Sorted oldest first, which is how a person reads a log.
  static func capLogs(_ logs: [FeedbackLogEntry]) -> [FeedbackLogEntry]? {
    guard !logs.isEmpty else { return nil }
    var kept = logs.sorted { $0.t < $1.t }.suffix(FeedbackLimits.logEntries).map { entry -> FeedbackLogEntry in
      var e = entry
      e.msg = FeedbackText.truncate(Redactor.redact(e.msg), FeedbackLimits.logMessage)
      e.src = FeedbackText.optional(e.src, FeedbackLimits.logSource)
      return e
    }
    let encoder = FeedbackPayload.encoder()
    // Each entry's own encoded size, plus a comma between them and the two brackets.
    var sizes = kept.map { (try? encoder.encode($0).count) ?? 0 }
    var total = sizes.reduce(0, +) + max(0, kept.count - 1) + 2
    while total > FeedbackLimits.logBytes, !kept.isEmpty {
      total -= sizes.removeFirst() + 1
      kept.removeFirst()
    }
    return kept.isEmpty ? nil : kept
  }

  static func capNetwork(_ entries: [FeedbackNetworkEntry]) -> [FeedbackNetworkEntry]? {
    guard !entries.isEmpty else { return nil }
    let kept = entries.sorted { $0.t < $1.t }.suffix(FeedbackLimits.networkEntries).map { entry -> FeedbackNetworkEntry in
      var e = entry
      let bare = URL(string: e.url).map(FeedbackText.strippedURL) ?? String(e.url.prefix { $0 != "?" && $0 != "#" })
      e.url = FeedbackText.truncate(Redactor.redact(bare), FeedbackLimits.networkURL, ellipsis: false)
      e.method = FeedbackText.truncate(e.method.uppercased(), FeedbackLimits.networkMethod, ellipsis: false)
      e.ms = max(0, e.ms)
      return e
    }
    return Array(kept)
  }

  /// The UTF-8 size of the encoded body.
  public func encodedSize() -> Int {
    (try? FeedbackPayload.encoder().encode(self).count) ?? 0
  }
}

extension FeedbackContext {
  func sanitized() -> FeedbackContext {
    var c = self
    c.platform = FeedbackText.truncate(platform, FeedbackLimits.shortField, ellipsis: false)
    c.url = FeedbackText.optional(url, FeedbackLimits.url, ellipsis: false)
    c.screen = FeedbackText.optional(screen, FeedbackLimits.screen)
    c.title = FeedbackText.optional(title, FeedbackLimits.title)
    c.appVersion = FeedbackText.optional(appVersion, FeedbackLimits.shortField, ellipsis: false)
    c.build = FeedbackText.optional(build, FeedbackLimits.shortField, ellipsis: false)
    c.os = FeedbackText.optional(os, FeedbackLimits.shortField, ellipsis: false)
    c.osVersion = FeedbackText.optional(osVersion, FeedbackLimits.shortField, ellipsis: false)
    c.device = FeedbackText.optional(device, FeedbackLimits.device, ellipsis: false)
    c.locale = FeedbackText.optional(locale, FeedbackLimits.shortField, ellipsis: false)
    c.timeZone = FeedbackText.optional(timeZone, FeedbackLimits.shortField, ellipsis: false)
    c.userAgent = FeedbackText.optional(userAgent, FeedbackLimits.userAgent)
    if let id = deviceId, !FeedbackText.isValidDeviceId(id) { c.deviceId = nil }
    if let vp = viewport, !(vp.w > 0 && vp.h > 0) { c.viewport = nil }
    if let extra, !extra.isEmpty {
      // At most 20 keys, chosen by sorted key so the same input always keeps the same ones.
      var kept: [String: String] = [:]
      for key in extra.keys.sorted() where !key.isEmpty {
        guard kept.count < FeedbackLimits.extraKeys else { break }
        kept[key] = FeedbackText.truncate(extra[key] ?? "", FeedbackLimits.extraValue)
      }
      c.extra = kept.isEmpty ? nil : kept
    } else {
      c.extra = nil
    }
    return c
  }
}
