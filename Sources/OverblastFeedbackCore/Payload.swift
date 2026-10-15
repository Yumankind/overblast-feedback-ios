import Foundation

// The body of `POST /v1/feedback`, version 1, exactly as the contract spells it.
//
// EVERY PROPERTY NAME HERE IS A WIRE KEY. The worker refuses an unknown top-level field by name, so
// a property added for convenience would turn every report into a 400. There are no `CodingKeys`
// renames anywhere: what you read below is what goes out. Optionals are left out of the JSON when
// they are nil (the synthesized `Codable` uses `encodeIfPresent`), because absent and empty are
// different statements and the worker only accepts the first.

/// What kind of report this is. The worker titles the task by it (`Bug:`, `Idea:`, `Question:`,
/// `Feedback:`).
public enum FeedbackCategory: String, Codable, Sendable, CaseIterable {
  case bug, idea, question, other
}

/// A log line's level. The contract has four, so `notice` and `fault` from the unified log are folded
/// into `info` and `error`.
public enum FeedbackLogLevel: String, Codable, Sendable, CaseIterable {
  case debug, info, warn, error
}

/// Who is reporting. Every field is optional. An `email` opens an email conversation on the task so
/// the team can answer; without one, nobody can be answered.
public struct FeedbackReporter: Codable, Sendable, Equatable {
  public var email: String?
  public var name: String?
  /// The integrator's own id for this person (a customer id, a user id). It is shown on the task.
  public var accountRef: String?

  public init(email: String? = nil, name: String? = nil, accountRef: String? = nil) {
    self.email = email
    self.name = name
    self.accountRef = accountRef
  }

  var isEmpty: Bool { email == nil && name == nil && accountRef == nil }
}

/// The context viewport: points and the device pixel ratio.
public struct FeedbackViewport: Codable, Sendable, Equatable {
  public var w: Double
  public var h: Double
  public var dpr: Double?

  public init(w: Double, h: Double, dpr: Double? = nil) {
    self.w = w
    self.h = h
    self.dpr = dpr
  }
}

/// The library that made the report.
public struct FeedbackSDK: Codable, Sendable, Equatable {
  public var name: String
  public var version: String

  public init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}

/// Where and on what the report was made.
public struct FeedbackContext: Codable, Sendable, Equatable {
  /// Always `ios` from this library.
  public var platform: String
  public var url: String?
  public var screen: String?
  public var title: String?
  public var appVersion: String?
  public var build: String?
  public var os: String?
  public var osVersion: String?
  public var device: String?
  public var locale: String?
  public var timeZone: String?
  public var viewport: FeedbackViewport?
  public var userAgent: String?
  public var sdk: FeedbackSDK?
  public var deviceId: String?
  public var extra: [String: String]?
  /// Unix milliseconds when the reporter opened the report: the sheet appearing, or `report()` being
  /// called (contract §3.4). The worker reads the logs up to here.
  public var openedAt: Int64?
  /// What opened it.
  public var trigger: FeedbackTrigger?

  public init(
    platform: String = "ios",
    url: String? = nil,
    screen: String? = nil,
    title: String? = nil,
    appVersion: String? = nil,
    build: String? = nil,
    os: String? = nil,
    osVersion: String? = nil,
    device: String? = nil,
    locale: String? = nil,
    timeZone: String? = nil,
    viewport: FeedbackViewport? = nil,
    userAgent: String? = nil,
    sdk: FeedbackSDK? = nil,
    deviceId: String? = nil,
    extra: [String: String]? = nil,
    openedAt: Int64? = nil,
    trigger: FeedbackTrigger? = nil
  ) {
    self.platform = platform
    self.url = url
    self.screen = screen
    self.title = title
    self.appVersion = appVersion
    self.build = build
    self.os = os
    self.osVersion = osVersion
    self.device = device
    self.locale = locale
    self.timeZone = timeZone
    self.viewport = viewport
    self.userAgent = userAgent
    self.sdk = sdk
    self.deviceId = deviceId
    self.extra = extra
    self.openedAt = openedAt
    self.trigger = trigger
  }
}

/// What opened the report (contract §3.1).
public enum FeedbackTrigger: String, Codable, Sendable, CaseIterable {
  case shake, button, shortcut, agent, api
  /// The offer made at the launch after the app closed unexpectedly.
  case relaunch
  /// The "Something may have gone wrong" prompt (contract §3.6).
  case errorPrompt = "error_prompt"
}

/// How the PREVIOUS session ended, when it ended unexpectedly (contract §3.4).
public struct FeedbackCrash: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case crash, exception, oom, killed, unknown
  }

  public enum Source: String, Codable, Sendable, CaseIterable {
    /// MetricKit's `MXCrashDiagnostic`, delivered at a later launch.
    case metrickit
    /// Android's exit reasons; never sent from this library.
    case exitInfo = "exit_info"
    /// This library's uncaught-exception handler.
    case handler
    /// Only the session marker: the session never closed and nothing says why.
    case marker
  }

  public var kind: Kind
  /// Unix milliseconds, when known.
  public var at: Int64?
  public var message: String?
  public var stack: String?
  public var source: Source

  public init(kind: Kind, at: Int64? = nil, message: String? = nil, stack: String? = nil, source: Source) {
    self.kind = kind
    self.at = at
    self.message = message
    self.stack = stack
    self.source = source
  }
}

/// A rectangle as fractions of the viewport, each in 0...1.
public struct FeedbackRect: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

/// The element viewport: points, no pixel ratio.
public struct FeedbackElementViewport: Codable, Sendable, Equatable {
  public var w: Double
  public var h: Double

  public init(w: Double, h: Double) {
    self.w = w
    self.h = h
  }
}

/// The selected element, `kind: "native"` (contract §3.2). Build one with `NativeAnchorBuilder`,
/// which applies the limits.
public struct FeedbackElement: Codable, Sendable, Equatable {
  public private(set) var kind: String = "native"
  public var path: [String]
  public var type: String
  public var id: String?
  public var label: String?
  public var rect: FeedbackRect
  public var viewport: FeedbackElementViewport

  public init(path: [String], type: String, id: String? = nil, label: String? = nil, rect: FeedbackRect, viewport: FeedbackElementViewport) {
    self.path = path
    self.type = type
    self.id = id
    self.label = label
    self.rect = rect
    self.viewport = viewport
  }
}

/// The screenshot, only when the reporter said yes.
public struct FeedbackScreenshot: Codable, Sendable, Equatable {
  /// `image/jpeg`, `image/png` or `image/webp`.
  public var contentType: String
  public var base64: String
  /// True when the selected element's box is drawn on the image.
  public var highlighted: Bool

  public init(contentType: String, base64: String, highlighted: Bool) {
    self.contentType = contentType
    self.base64 = base64
    self.highlighted = highlighted
  }

  public init(jpeg data: Data, highlighted: Bool) {
    self.init(contentType: "image/jpeg", base64: data.base64EncodedString(), highlighted: highlighted)
  }

  /// The decoded size, which is what the 5 MB limit is measured on.
  public var decodedByteCount: Int {
    // base64 is 4 characters per 3 bytes, less the padding.
    let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
    return max(0, base64.utf8.count / 4 * 3 - padding)
  }
}

/// One log line. `t` is unix milliseconds.
public struct FeedbackLogEntry: Codable, Sendable, Equatable {
  public var t: Int64
  public var level: FeedbackLogLevel
  public var msg: String
  public var src: String?
  /// How many times this line was logged in a row, when more than once (contract §3.5). `repeat` on
  /// the wire.
  public var repeatCount: Int?
  /// Unix milliseconds of the last repeat, with `repeatCount`.
  public var last: Int64?

  enum CodingKeys: String, CodingKey {
    case t, level, msg, src
    case repeatCount = "repeat"
    case last
  }

  public init(t: Int64, level: FeedbackLogLevel, msg: String, src: String? = nil, repeatCount: Int? = nil, last: Int64? = nil) {
    self.t = t
    self.level = level
    self.msg = msg
    self.src = src
    self.repeatCount = repeatCount
    self.last = last
  }
}

/// The whole log as a file (contract §3.5): NDJSON, one entry per line, oldest first, gzip.
public struct FeedbackLogFile: Codable, Sendable, Equatable {
  public var contentType: String
  /// `gzip` or `identity`.
  public var encoding: String
  public var base64: String
  public var lines: Int
  public var from: Int64
  public var to: Int64

  public init(contentType: String = "application/x-ndjson", encoding: String, base64: String, lines: Int, from: Int64, to: Int64) {
    self.contentType = contentType
    self.encoding = encoding
    self.base64 = base64
    self.lines = lines
    self.from = from
    self.to = to
  }

  /// The size of the file as sent, before base64.
  public var decodedByteCount: Int {
    let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
    return max(0, base64.utf8.count / 4 * 3 - padding)
  }
}

/// One network request. No bodies, no headers, and no query string or fragment on `url`.
/// `status` 0 means the request was never answered.
public struct FeedbackNetworkEntry: Codable, Sendable, Equatable {
  public var t: Int64
  public var method: String
  public var url: String
  public var status: Int
  public var ms: Int

  public init(t: Int64, method: String, url: String, status: Int, ms: Int) {
    self.t = t
    self.method = method
    self.url = url
    self.status = status
    self.ms = ms
  }
}

/// The whole body.
public struct FeedbackPayload: Codable, Sendable, Equatable {
  public private(set) var v: Int = 1
  public var message: String
  public var category: FeedbackCategory
  public var reporter: FeedbackReporter?
  public var context: FeedbackContext
  public var element: FeedbackElement?
  public var screenshot: FeedbackScreenshot?
  public var logs: [FeedbackLogEntry]?
  /// Everything the log buffer held, as a compressed file (contract §3.5).
  public var logFile: FeedbackLogFile?
  public var network: [FeedbackNetworkEntry]?
  /// The previous session's unexpected end, on a report made at the next launch.
  public var crash: FeedbackCrash?

  public init(
    message: String,
    category: FeedbackCategory = .bug,
    reporter: FeedbackReporter? = nil,
    context: FeedbackContext,
    element: FeedbackElement? = nil,
    screenshot: FeedbackScreenshot? = nil,
    logs: [FeedbackLogEntry]? = nil,
    network: [FeedbackNetworkEntry]? = nil,
    crash: FeedbackCrash? = nil,
    logFile: FeedbackLogFile? = nil
  ) {
    self.message = message
    self.category = category
    self.reporter = reporter
    self.context = context
    self.element = element
    self.screenshot = screenshot
    self.logs = logs
    self.network = network
    self.crash = crash
    self.logFile = logFile
  }

  /// The encoder the client sends with. Slashes are not escaped, so a URL in a log line costs what
  /// it costs in JavaScript and the 256 KB budget is measured the way the worker measures it.
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return encoder
  }
}

/// The worker's `201`.
public struct FeedbackReceipt: Codable, Sendable, Equatable {
  /// `fbr_...`
  public var id: String
  public var taskId: String
  /// Present only when the reporter gave an email address.
  public var conversationId: String?

  public init(id: String, taskId: String, conversationId: String?) {
    self.id = id
    self.taskId = taskId
    self.conversationId = conversationId
  }
}
