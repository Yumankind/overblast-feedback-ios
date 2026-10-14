import Foundation

/// The one request this library makes: `POST /v1/feedback` with the key in a header.
public struct FeedbackClient: Sendable {
  public static let defaultEndpoint = URL(string: "https://brain.deployd.network/v1/feedback")!
  public static let keyHeader = "X-Overblast-Feedback-Key"

  public let endpoint: URL
  public let key: String
  let session: URLSession

  /// `session` defaults to an ephemeral one of the library's own: no cookies, no cache, and none of
  /// the app's registered `URLProtocol`s (the network recorder among them), so the report is not
  /// recorded into the next report.
  public init(endpoint: URL = FeedbackClient.defaultEndpoint, key: String, session: URLSession? = nil) {
    self.endpoint = endpoint
    self.key = key
    self.session = session ?? FeedbackClient.makeSession()
  }

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 90
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }

  /// Sends a payload that has already been through `sanitized()`.
  public func send(_ payload: FeedbackPayload) async throws -> FeedbackReceipt {
    let body: Data
    do {
      body = try FeedbackPayload.encoder().encode(payload)
    } catch {
      throw FeedbackError.invalidReport(field: "body", message: "The report could not be prepared.")
    }
    guard body.count <= FeedbackLimits.bodyBytes else {
      throw FeedbackError.invalidReport(field: "body", message: "The report is too large to send. Try it without the screenshot.")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(key, forHTTPHeaderField: Self.keyHeader)
    request.httpBody = body

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw Self.mapTransport(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw FeedbackError.offline(message: "The feedback service did not answer.")
    }
    return try Self.interpret(status: http.statusCode, data: data, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
  }

  /// The worker's refusal body: `{ code, error, field?, retryAfter? }`.
  struct Refusal: Decodable {
    var code: String?
    var error: String?
    var field: String?
    var retryAfter: Double?
  }

  /// The answer, mapped per contract §3.3. Public for tests and for apps that send the body
  /// themselves.
  public static func interpret(status: Int, data: Data, retryAfterHeader: String? = nil) throws -> FeedbackReceipt {
    if (200..<300).contains(status) {
      guard let receipt = try? JSONDecoder().decode(FeedbackReceipt.self, from: data) else {
        // Filed, by the status, but in a shape this version cannot read. Not worth a resend.
        return FeedbackReceipt(id: "", taskId: "", conversationId: nil)
      }
      return receipt
    }

    let refusal = try? JSONDecoder().decode(Refusal.self, from: data)
    let code = refusal?.code ?? ""
    let sentence = refusal?.error.flatMap { $0.isEmpty ? nil : $0 }

    switch (status, code) {
    case (429, _):
      let seconds = refusal?.retryAfter.map { Int($0.rounded(.up)) } ?? retryAfterHeader.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      throw FeedbackError.rateLimited(retryAfter: seconds, message: sentence ?? "Too many reports for now. This one is saved and will be sent later.")
    case (507, _):
      throw FeedbackError.storageFull(message: sentence ?? "Your report was filed, but the screenshot could not be stored.")
    case (502, _), (503, _), (504, _):
      throw FeedbackError.offline(message: sentence ?? "The feedback service is not answering right now. Your report is saved and will be sent later.")
    default:
      throw FeedbackError.refused(
        status: status,
        code: code.isEmpty ? defaultCode(status) : code,
        message: sentence ?? defaultSentence(status),
        field: refusal?.field
      )
    }
  }

  static func defaultCode(_ status: Int) -> String {
    switch status {
    case 400: return "invalid_field"
    case 401: return "unknown_key"
    case 403: return "key_disabled"
    case 413: return "too_large"
    case 500: return "misconfigured"
    default: return "http_\(status)"
    }
  }

  static func defaultSentence(_ status: Int) -> String {
    switch status {
    case 400: return "The report was not accepted."
    case 401, 403: return "Feedback is not accepted from this app right now."
    case 413: return "The report is too large. Try it without the screenshot."
    default: return "The feedback service could not take the report (HTTP \(status))."
    }
  }

  static func mapTransport(_ error: Error) -> FeedbackError {
    let offlineCodes: Set<URLError.Code> = [
      .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
      .cancelled,
    ]
    if let url = error as? URLError, offlineCodes.contains(url.code) {
      return .offline(message: "You appear to be offline. Your report is saved and will be sent later.")
    }
    return .offline(message: "The report could not be sent. It is saved and will be sent later.")
  }
}
